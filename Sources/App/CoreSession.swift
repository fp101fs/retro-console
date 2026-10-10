import Foundation

/// One running core. Confined to the emulation thread. Mirrors the original CoreSession plus
/// EnvironmentHandler: libretro callbacks are context-free C functions, so the running session
/// lives in one static slot, and only the allow-listed environment commands are answered.
final class CoreSession {
    static var current: CoreSession?

    let library: CoreLibrary
    let coreURL: URL

    var pixelFormat: PixelFormat = .rgb1555
    var hardwareRenderRequested = false
    var fps = 60.0
    var sampleRate = 44100.0
    var aspect = 4.0 / 3.0

    var onVideo: ((UnsafeRawPointer, Int, Int, Int, PixelFormat) -> Void)?
    var onAudio: ((UnsafePointer<Int16>, Int) -> Void)?
    var onTimingChange: (() -> Void)?
    var inputProvider: () -> UInt32 = { 0 }

    fileprivate var polledInput: UInt32 = 0
    private let systemDirectoryC: UnsafeMutablePointer<CChar>
    private let saveDirectoryC: UnsafeMutablePointer<CChar>
    private let corePathC: UnsafeMutablePointer<CChar>
    private var variableDefaults: [String: UnsafeMutablePointer<CChar>] = [:]
    private var isShutdown = false
    private var gameLoaded = false

    init(coreURL: URL, systemDirectory: URL, saveDirectory: URL) throws {
        guard CoreSession.current == nil else { throw CoreError.alreadyActive }
        library = try CoreLibrary(url: coreURL)
        self.coreURL = coreURL
        systemDirectoryC = strdup(systemDirectory.path)
        saveDirectoryC = strdup(saveDirectory.path)
        corePathC = strdup(coreURL.path)
        CoreSession.current = self

        // Spec order: environment callback first, then the rest, then retro_init.
        library.symbols.setEnvironment { command, data in
            CoreSession.current?.handleEnvironment(command: command, data: data) ?? false
        }
        library.symbols.setVideoRefresh { data, width, height, pitch in
            CoreSession.current?.captureVideo(data: data, width: Int(width), height: Int(height), pitch: pitch)
        }
        library.symbols.setAudioSample { left, right in
            CoreSession.current?.captureSample(left, right)
        }
        library.symbols.setAudioSampleBatch { data, frames in
            guard let data, frames > 0, let session = CoreSession.current else { return frames }
            session.onAudio?(data, frames)
            return frames
        }
        library.symbols.setInputPoll {
            if let session = CoreSession.current { session.polledInput = session.inputProvider() }
        }
        library.symbols.setInputState { port, device, _, id in
            guard port == 0, (device & 0xFF) == Retro.deviceJoypad,
                let bits = CoreSession.current?.polledInput else { return 0 }
            if id == Retro.joypadMask { return Int16(truncatingIfNeeded: bits & 0xFFFF) }
            return id < 16 ? Int16((bits >> id) & 1) : 0
        }
        library.symbols.initCore()
    }

    deinit { shutdown() }

    // MARK: Loading

    func loadGame(path: String) throws {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        library.symbols.getSystemInfo(raw)
        let needsFullPath = raw.load(fromByteOffset: 24, as: Bool.self)

        var contents: Data?
        if !needsFullPath {
            // Cartridge content is read by the host; absurd sizes are refused (original: 64 MB cap).
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            if let size = attributes?[.size] as? Int, size > 64 * 1024 * 1024 { throw CoreError.tooLarge(size) }
            guard let data = FileManager.default.contents(atPath: path) else { throw CoreError.unreadableGame }
            contents = data
        }
        let info = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { info.deallocate() }
        info.initializeMemory(as: UInt8.self, repeating: 0, count: 64)

        let loaded = path.withCString { cPath -> Bool in
            info.storeBytes(of: cPath, toByteOffset: 0, as: UnsafePointer<CChar>?.self)
            if let contents {
                return contents.withUnsafeBytes { buffer -> Bool in
                    info.storeBytes(of: buffer.baseAddress, toByteOffset: 8, as: UnsafeRawPointer?.self)
                    info.storeBytes(of: buffer.count, toByteOffset: 16, as: Int.self)
                    return library.symbols.loadGame(UnsafeRawPointer(info))
                }
            }
            return library.symbols.loadGame(UnsafeRawPointer(info))
        }
        guard loaded else { throw CoreError.gameRejected }
        gameLoaded = true
        if hardwareRenderRequested {
            library.symbols.unloadGame()
            gameLoaded = false
            throw CoreError.hardwareRenderUnsupported
        }

        let av = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { av.deallocate() }
        av.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        library.symbols.getSystemAVInfo(av)
        applyGeometry(av)
        let fpsValue = av.load(fromByteOffset: 24, as: Double.self)
        let rate = av.load(fromByteOffset: 32, as: Double.self)
        if fpsValue > 1 { fps = fpsValue }
        if rate > 1000 { sampleRate = rate }
    }

    private func applyGeometry(_ geometry: UnsafeRawPointer) {
        let baseW = Double(geometry.load(fromByteOffset: 0, as: UInt32.self))
        let baseH = Double(geometry.load(fromByteOffset: 4, as: UInt32.self))
        let reported = Double(geometry.load(fromByteOffset: 16, as: Float.self))
        if reported > 0.1 {
            aspect = reported
        } else if baseW > 0, baseH > 0 {
            aspect = baseW / baseH
        }
    }

    // MARK: Running

    func runFrame() { library.symbols.run() }
    func reset() { library.symbols.reset() }

    func saveRAMSnapshot() -> Data? {
        let size = library.symbols.getMemorySize(Retro.memorySaveRAM)
        guard size > 0, let pointer = library.symbols.getMemoryData(Retro.memorySaveRAM) else { return nil }
        return Data(bytes: pointer, count: size)
    }

    @discardableResult
    func restoreSaveRAM(_ data: Data) -> Bool {
        let size = library.symbols.getMemorySize(Retro.memorySaveRAM)
        guard size > 0, size == data.count, let pointer = library.symbols.getMemoryData(Retro.memorySaveRAM) else { return false }
        data.withUnsafeBytes { source in
            if let base = source.baseAddress { pointer.copyMemory(from: base, byteCount: size) }
        }
        return true
    }

    func serialize() throws -> Data {
        let size = library.symbols.serializeSize()
        guard size > 0 else { throw CoreError.serializationFailed }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { library.symbols.serialize($0.baseAddress, size) }
        guard ok else { throw CoreError.serializationFailed }
        return data
    }

    func unserialize(_ data: Data) throws {
        let ok = data.withUnsafeBytes { library.symbols.unserialize($0.baseAddress, data.count) }
        guard ok else { throw CoreError.serializationFailed }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        if gameLoaded { library.symbols.unloadGame() }
        library.symbols.deinitCore()
        if CoreSession.current === self { CoreSession.current = nil }
        free(systemDirectoryC)
        free(saveDirectoryC)
        free(corePathC)
        variableDefaults.values.forEach { free($0) }
        variableDefaults.removeAll()
    }

    // MARK: Callbacks

    fileprivate func captureVideo(data: UnsafeRawPointer?, width: Int, height: Int, pitch: Int) {
        // nil data = "duplicate frame" (GET_CAN_DUPE is advertised): keep the previous one.
        guard let data, width > 0, height > 0, pitch >= width * pixelFormat.bytesPerPixel else { return }
        onVideo?(data, width, height, pitch, pixelFormat)
    }

    fileprivate func captureSample(_ left: Int16, _ right: Int16) {
        var pair: (Int16, Int16) = (left, right)
        withUnsafePointer(to: &pair) { pointer in
            pointer.withMemoryRebound(to: Int16.self, capacity: 2) { onAudio?($0, 1) }
        }
    }

    /// Allow-listed environment commands; anything unknown is refused.
    fileprivate func handleEnvironment(command rawCommand: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
        let command = rawCommand & 0xFFFF
        switch command {
        case Retro.envGetCanDupe:
            data?.assumingMemoryBound(to: Bool.self).pointee = true
            return true
        case Retro.envSetPerformanceLevel, Retro.envSetInputDescriptors, Retro.envSetControllerInfo,
            Retro.envSetSupportNoGame, Retro.envSetMessage, Retro.envSetCoreOptionsDisplay:
            return true
        case Retro.envSetSerializationQuirks:
            return data != nil
        case Retro.envGetSystemDirectory:
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(systemDirectoryC)
            return true
        case Retro.envGetSaveDirectory:
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(saveDirectoryC)
            return true
        case Retro.envGetLibretroPath:
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(corePathC)
            return true
        case Retro.envSetPixelFormat:
            guard let data, let format = PixelFormat(raw: data.load(as: UInt32.self)) else { return false }
            pixelFormat = format
            return true
        case Retro.envSetHWRender:
            hardwareRenderRequested = true
            return false
        case Retro.envSetVariables:
            // Legacy option list: remember each option's first (default) value for GET_VARIABLE.
            guard let data else { return true }
            var cursor = data
            while let keyPointer = cursor.load(as: UnsafePointer<CChar>?.self) {
                if let valuePointer = cursor.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self) {
                    let text = String(cString: valuePointer)
                    if let range = text.range(of: "; ") {
                        let first = text[range.upperBound...].split(separator: "|").first.map(String.init) ?? ""
                        let key = String(cString: keyPointer)
                        if let old = variableDefaults[key] { free(old) }
                        variableDefaults[key] = strdup(first)
                    }
                }
                cursor += 16
            }
            return true
        case Retro.envGetVariable:
            guard let data else { return true }
            var value: UnsafePointer<CChar>?
            if let keyPointer = data.load(as: UnsafePointer<CChar>?.self),
                let stored = variableDefaults[String(cString: keyPointer)] {
                value = UnsafePointer(stored)
            }
            data.storeBytes(of: value, toByteOffset: 8, as: UnsafePointer<CChar>?.self)
            return true
        case Retro.envGetVariableUpdate:
            data?.assumingMemoryBound(to: Bool.self).pointee = false
            return true
        case Retro.envGetInputBitmasks:
            return true
        case Retro.envSetGeometry:
            if let data { applyGeometry(data) }
            return true
        case Retro.envSetSystemAVInfo:
            guard let data else { return false }
            applyGeometry(data)
            let fpsValue = data.load(fromByteOffset: 24, as: Double.self)
            let rate = data.load(fromByteOffset: 32, as: Double.self)
            if fpsValue > 1 { fps = fpsValue }
            if rate > 1000 { sampleRate = rate }
            onTimingChange?()
            return true
        default:
            // Includes core options v1/v2 (version query is refused so cores use SET_VARIABLES),
            // the variadic log interface, VFS, rumble, sensors, hardware render negotiation.
            return false
        }
    }
}
