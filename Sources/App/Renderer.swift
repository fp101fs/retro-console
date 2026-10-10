import Foundation
import MetalKit
import SwiftUI

struct VideoFrame {
    let bytes: [UInt8]   // tightly packed BGRA8
    let width: Int
    let height: Int
    let serial: UInt64
}

/// Hand-off between the emulation thread (writer) and the Metal view (reader).
final class FrameBox {
    private let lock = NSLock()
    private var frame: VideoFrame?
    private var _aspect = 4.0 / 3.0
    private var serial: UInt64 = 0

    func store(bytes: [UInt8], width: Int, height: Int) {
        lock.lock()
        serial += 1
        frame = VideoFrame(bytes: bytes, width: width, height: height, serial: serial)
        lock.unlock()
    }

    var aspect: Double {
        get { lock.lock(); defer { lock.unlock() }; return _aspect }
        set { lock.lock(); _aspect = newValue; lock.unlock() }
    }

    func snapshot() -> VideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }
}

/// Converts core framebuffers to tightly packed BGRA8 (from the original PixelConverter).
enum PixelConverter {
    static func bgra(from source: UnsafeRawPointer, width: Int, height: Int, pitch: Int, format: PixelFormat) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        out.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            for y in 0..<height {
                let row = source + y * pitch
                let target = base + y * width * 4
                switch format {
                case .xrgb8888:
                    // Little-endian 0xXXRRGGBB is already [B, G, R, X] in memory.
                    memcpy(target, row, width * 4)
                    for x in 0..<width { target[x * 4 + 3] = 255 }
                case .rgb565:
                    let pixels = row.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let v = pixels[x]
                        let r = UInt8((v >> 11) & 0x1F), g = UInt8((v >> 5) & 0x3F), b = UInt8(v & 0x1F)
                        target[x * 4] = (b << 3) | (b >> 2)
                        target[x * 4 + 1] = (g << 2) | (g >> 4)
                        target[x * 4 + 2] = (r << 3) | (r >> 2)
                    }
                case .rgb1555:
                    let pixels = row.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let v = pixels[x]
                        let r = UInt8((v >> 10) & 0x1F), g = UInt8((v >> 5) & 0x1F), b = UInt8(v & 0x1F)
                        target[x * 4] = (b << 3) | (b >> 2)
                        target[x * 4 + 1] = (g << 3) | (g >> 2)
                        target[x * 4 + 2] = (r << 3) | (r >> 2)
                    }
                }
            }
        }
        return out
    }
}

/// Placement math (from the original IntegerScaler).
enum IntegerScaler {
    struct Rect { let x: Int, y: Int, width: Int, height: Int }

    static func destination(frameWidth: Int, frameHeight: Int, aspect: Double, drawableWidth: Int, drawableHeight: Int, integerOnly: Bool) -> Rect {
        guard frameWidth > 0, frameHeight > 0, drawableWidth > 0, drawableHeight > 0 else {
            return Rect(x: 0, y: 0, width: max(drawableWidth, 1), height: max(drawableHeight, 1))
        }
        let width: Int, height: Int
        if integerOnly {
            // Scale the aspect-corrected size by the largest whole factor that fits.
            let correctedWidth = max(1, Int((Double(frameHeight) * aspect).rounded()))
            let scale = max(1, min(drawableWidth / correctedWidth, drawableHeight / frameHeight))
            width = correctedWidth * scale
            height = frameHeight * scale
        } else if Double(drawableWidth) / Double(drawableHeight) > aspect {
            height = drawableHeight
            width = Int((Double(drawableHeight) * aspect).rounded())
        } else {
            width = drawableWidth
            height = Int((Double(drawableWidth) / aspect).rounded())
        }
        return Rect(x: (drawableWidth - width) / 2, y: (drawableHeight - height) / 2, width: width, height: height)
    }
}

/// Metal presenter: draws the latest core frame with a nearest/linear filter and an optional
/// scanline (CRT) pass. The effect is a few lines in the fragment shader, switched off by a uniform.
final class Renderer: NSObject, MTKViewDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float crt;        // 1 = scanline effect on
        float srcHeight;  // source rows
        float smooth;     // 1 = linear filter, 0 = nearest
        float padding;
    };

    vertex VertexOut blit_vertex(uint vid [[vertex_id]]) {
        float2 positions[4] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
        float2 uvs[4] = {float2(0,1), float2(1,1), float2(0,0), float2(1,0)};
        VertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 blit_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
        constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float4 color = u.smooth > 0.5 ? source.sample(linearSampler, in.uv) : source.sample(nearestSampler, in.uv);
        if (u.crt > 0.5) {
            // Bright in the middle of each source row, darker between rows.
            float line = in.uv.y * u.srcHeight;
            float beam = 0.5 + 0.5 * cos(6.2831853 * (line - 0.5));
            color.rgb *= mix(0.55, 1.0, beam) * 1.12;
        }
        return float4(saturate(color.rgb), 1.0);
    }
    """

    private struct Uniforms {
        var crt: Float
        var srcHeight: Float
        var smooth: Float
        var padding: Float = 0
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let box: FrameBox
    private var texture: MTLTexture?
    private var uploadedSerial: UInt64 = 0
    private(set) var failureMessage: String?

    init?(device: MTLDevice, box: FrameBox) {
        guard let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertex = library.makeFunction(name: "blit_vertex"),
            let fragment = library.makeFunction(name: "blit_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.box = box
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
            let commands = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let frame = box.snapshot() {
            if texture == nil || texture?.width != frame.width || texture?.height != frame.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
                descriptor.usage = [.shaderRead]
                texture = view.device?.makeTexture(descriptor: descriptor)
                uploadedSerial = 0
            }
            if let texture, uploadedSerial != frame.serial {
                frame.bytes.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress {
                        texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                                        withBytes: base, bytesPerRow: frame.width * 4)
                    }
                }
                uploadedSerial = frame.serial
            }
            if let texture, let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
                let settings = AppSettings.shared
                let size = view.drawableSize
                let rect = IntegerScaler.destination(
                    frameWidth: frame.width, frameHeight: frame.height, aspect: box.aspect,
                    drawableWidth: Int(size.width), drawableHeight: Int(size.height),
                    integerOnly: settings.scaleMode == .integer)
                var uniforms = Uniforms(
                    crt: settings.crtEffect ? 1 : 0, srcHeight: Float(frame.height),
                    smooth: settings.filter == .smooth ? 1 : 0)
                encoder.setRenderPipelineState(pipeline)
                encoder.setViewport(MTLViewport(
                    originX: Double(rect.x), originY: Double(rect.y), width: Double(rect.width),
                    height: Double(rect.height), znear: 0, zfar: 1))
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        } else if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.commit()
    }
}

struct GameMetalView: NSViewRepresentable {
    let box: FrameBox

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let device = view.device, let renderer = Renderer(device: device, box: box) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
