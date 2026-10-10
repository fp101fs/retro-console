import Foundation

// The libretro C ABI, restated in Swift. The original project imports libretro.h through a
// C target; this package has a single Swift target, so the few structures a frontend needs are
// read and written at explicit byte offsets (64-bit layout) instead.

enum PixelFormat {
    case rgb1555, xrgb8888, rgb565

    init?(raw: UInt32) {
        switch raw {
        case 0: self = .rgb1555
        case 1: self = .xrgb8888
        case 2: self = .rgb565
        default: return nil
        }
    }

    var bytesPerPixel: Int { self == .xrgb8888 ? 4 : 2 }
}

enum Retro {
    static let apiVersion: UInt32 = 1
    static let deviceJoypad: UInt32 = 1
    static let joypadMask: UInt32 = 256
    static let memorySaveRAM: UInt32 = 0

    // Environment commands (experimental/private flag bits are stripped before matching).
    static let envSetRotation: UInt32 = 1
    static let envGetCanDupe: UInt32 = 3
    static let envSetMessage: UInt32 = 6
    static let envSetPerformanceLevel: UInt32 = 8
    static let envGetSystemDirectory: UInt32 = 9
    static let envSetPixelFormat: UInt32 = 10
    static let envSetInputDescriptors: UInt32 = 11
    static let envSetHWRender: UInt32 = 14
    static let envGetVariable: UInt32 = 15
    static let envSetVariables: UInt32 = 16
    static let envGetVariableUpdate: UInt32 = 17
    static let envSetSupportNoGame: UInt32 = 18
    static let envGetLibretroPath: UInt32 = 19
    static let envGetSaveDirectory: UInt32 = 31
    static let envSetSystemAVInfo: UInt32 = 32
    static let envSetControllerInfo: UInt32 = 35
    static let envSetGeometry: UInt32 = 37
    static let envSetSerializationQuirks: UInt32 = 44
    static let envGetInputBitmasks: UInt32 = 51
    static let envSetCoreOptionsDisplay: UInt32 = 55
}

typealias EnvironmentCallback = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
typealias VideoRefreshCallback = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void
typealias AudioSampleCallback = @convention(c) (Int16, Int16) -> Void
typealias AudioBatchCallback = @convention(c) (UnsafePointer<Int16>?, Int) -> Int
typealias InputPollCallback = @convention(c) () -> Void
typealias InputStateCallback = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16

/// RetroPad buttons; `bit` is the libretro RETRO_DEVICE_ID_JOYPAD_* value.
enum RetroButton: String, Codable, CaseIterable, Identifiable {
    case b, y, select, start, up, down, left, right, a, x, l, r, l2, r2, l3, r3

    var id: String { rawValue }

    var bit: UInt32 {
        switch self {
        case .b: return 0
        case .y: return 1
        case .select: return 2
        case .start: return 3
        case .up: return 4
        case .down: return 5
        case .left: return 6
        case .right: return 7
        case .a: return 8
        case .x: return 9
        case .l: return 10
        case .r: return 11
        case .l2: return 12
        case .r2: return 13
        case .l3: return 14
        case .r3: return 15
        }
    }

    var label: String {
        switch self {
        case .up: return "D-Pad Up"
        case .down: return "D-Pad Down"
        case .left: return "D-Pad Left"
        case .right: return "D-Pad Right"
        case .select: return "Select"
        case .start: return "Start"
        default: return rawValue.uppercased()
        }
    }
}
