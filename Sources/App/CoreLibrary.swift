import Combine
import Foundation

enum CoreError: LocalizedError {
    case openFailed(String)
    case missingSymbol(String)
    case unsupportedAPI(UInt32)
    case gameRejected
    case hardwareRenderUnsupported
    case unreadableGame
    case tooLarge(Int)
    case serializationFailed
    case alreadyActive
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let r): return "The core could not be opened: \(r)"
        case .missingSymbol(let s): return "The file is not a libretro core (missing \(s))."
        case .unsupportedAPI(let v): return "The core uses libretro API version \(v), which this app does not support."
        case .gameRejected: return "The core refused to load this game. The file may be damaged, in an unsupported format, or the core may need a BIOS file."
        case .hardwareRenderUnsupported: return "This core needs hardware (OpenGL/Vulkan) rendering, which is not supported. Use a software-rendered build of the core."
        case .unreadableGame: return "The game file could not be read."
        case .tooLarge(let n): return "The game file is \(n / 1_048_576) MB, which is larger than a cartridge can be."
        case .serializationFailed: return "The core could not save or load the state."
        case .alreadyActive: return "Another game is still running."
        case .installFailed(let r): return "The core could not be installed: \(r)"
        }
    }
}

/// The libretro entry points a core must export (same set as the original CoreSymbols).
struct CoreSymbols {
    let apiVersion: @convention(c) () -> UInt32
    let initCore: @convention(c) () -> Void
    let deinitCore: @convention(c) () -> Void
    let getSystemInfo: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let getSystemAVInfo: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let setEnvironment: @convention(c) (EnvironmentCallback?) -> Void
    let setVideoRefresh: @convention(c) (VideoRefreshCallback?) -> Void
    let setAudioSample: @convention(c) (AudioSampleCallback?) -> Void
    let setAudioSampleBatch: @convention(c) (AudioBatchCallback?) -> Void
    let setInputPoll: @convention(c) (InputPollCallback?) -> Void
    let setInputState: @convention(c) (InputStateCallback?) -> Void
    let loadGame: @convention(c) (UnsafeRawPointer?) -> Bool
    let unloadGame: @convention(c) () -> Void
    let run: @convention(c) () -> Void
    let reset: @convention(c) () -> Void
    let serializeSize: @convention(c) () -> Int
    let serialize: @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool
    let unserialize: @convention(c) (UnsafeRawPointer?, Int) -> Bool
    let getMemoryData: @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    let getMemorySize: @convention(c) (UInt32) -> Int
}

/// An opened core dylib: dlopen, resolve every symbol, check the API version.
final class CoreLibrary {
    let symbols: CoreSymbols
    private let handle: UnsafeMutableRawPointer

    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
            throw CoreError.openFailed(reason)
        }
        func resolve<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw CoreError.missingSymbol(name) }
            return unsafeBitCast(symbol, to: T.self)
        }
        do {
            let symbols = CoreSymbols(
                apiVersion: try resolve("retro_api_version", (@convention(c) () -> UInt32).self),
                initCore: try resolve("retro_init", (@convention(c) () -> Void).self),
                deinitCore: try resolve("retro_deinit", (@convention(c) () -> Void).self),
                getSystemInfo: try resolve("retro_get_system_info", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
                getSystemAVInfo: try resolve("retro_get_system_av_info", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
                setEnvironment: try resolve("retro_set_environment", (@convention(c) (EnvironmentCallback?) -> Void).self),
                setVideoRefresh: try resolve("retro_set_video_refresh", (@convention(c) (VideoRefreshCallback?) -> Void).self),
                setAudioSample: try resolve("retro_set_audio_sample", (@convention(c) (AudioSampleCallback?) -> Void).self),
                setAudioSampleBatch: try resolve("retro_set_audio_sample_batch", (@convention(c) (AudioBatchCallback?) -> Void).self),
                setInputPoll: try resolve("retro_set_input_poll", (@convention(c) (InputPollCallback?) -> Void).self),
                setInputState: try resolve("retro_set_input_state", (@convention(c) (InputStateCallback?) -> Void).self),
                loadGame: try resolve("retro_load_game", (@convention(c) (UnsafeRawPointer?) -> Bool).self),
                unloadGame: try resolve("retro_unload_game", (@convention(c) () -> Void).self),
                run: try resolve("retro_run", (@convention(c) () -> Void).self),
                reset: try resolve("retro_reset", (@convention(c) () -> Void).self),
                serializeSize: try resolve("retro_serialize_size", (@convention(c) () -> Int).self),
                serialize: try resolve("retro_serialize", (@convention(c) (UnsafeMutableRawPointer?, Int) -> Bool).self),
                unserialize: try resolve("retro_unserialize", (@convention(c) (UnsafeRawPointer?, Int) -> Bool).self),
                getMemoryData: try resolve("retro_get_memory_data", (@convention(c) (UInt32) -> UnsafeMutableRawPointer?).self),
                getMemorySize: try resolve("retro_get_memory_size", (@convention(c) (UInt32) -> Int).self)
            )
            let version = symbols.apiVersion()
            guard version == Retro.apiVersion else { throw CoreError.unsupportedAPI(version) }
            self.symbols = symbols
            self.handle = handle
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit { dlclose(handle) }
}

/// What a core says about itself (retro_get_system_info).
struct CoreInfo: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let version: String
    let extensions: [String]
    let needsFullPath: Bool

    var fileName: String { url.lastPathComponent.lowercased() }
}

/// A core published on the libretro build server (buildbot.libretro.com, the same place RetroArch
/// gets its cores). Fetched only when the user presses Download or opens a game that needs it.
struct CoreDownload: Identifiable, Hashable {
    let id: String          // file stem, e.g. "snes9x" → snes9x_libretro.dylib
    let name: String
    let systems: String

    var archiveName: String { "\(id)_libretro.dylib.zip" }

    var url: URL {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return URL(string: "https://buildbot.libretro.com/nightly/apple/osx/\(arch)/latest/\(archiveName)")!
    }

    static let all: [CoreDownload] = [
        CoreDownload(id: "snes9x", name: "Snes9x", systems: "Super Nintendo"),
        CoreDownload(id: "genesis_plus_gx", name: "Genesis Plus GX", systems: "Genesis, Master System, Game Gear, SG-1000, Sega CD"),
        CoreDownload(id: "mgba", name: "mGBA", systems: "Game Boy, Game Boy Color, Game Boy Advance"),
        CoreDownload(id: "mednafen_psx", name: "Beetle PSX", systems: "PlayStation"),
    ]
}

/// Finds and registers the libretro cores available to the app. The original project
/// scanned a PlugIns directory; this one also scans a user folder in Application Support,
/// because cores are not bundled with this package.
final class CoreCatalog: ObservableObject {
    static let shared = CoreCatalog()

    @Published private(set) var cores: [CoreInfo] = []
    @Published private(set) var isRefreshing = false

    func refresh(completion: (() -> Void)? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.refresh(completion: completion) }
            return
        }
        isRefreshing = true
        var directories = [AppPaths.coresDirectory]
        if let bundled = AppPaths.bundledCoresDirectory { directories.append(bundled) }
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [CoreInfo] = []
            for directory in directories {
                let listing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for url in listing.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "dylib" {
                    if let info = Self.probe(url) { found.append(info) }
                }
            }
            DispatchQueue.main.async {
                self.cores = found
                self.isRefreshing = false
                completion?()
            }
        }
    }

    // MARK: Download

    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var downloadErrors: [String: String] = [:]
    private var waiters: [String: [(Result<Void, Error>) -> Void]] = [:]

    /// The download entry for the core that plays a system.
    static func download(for system: GameSystem) -> CoreDownload? {
        CoreDownload.all.first { item in system.coreKeys.contains(item.id) }
    }

    /// Installed core matching a download entry, if any.
    func installed(_ item: CoreDownload) -> CoreInfo? {
        cores.first { $0.fileName.contains(item.id) && !$0.fileName.contains("_hw") }
    }

    /// Downloads the core's published build, unzips it, signs it and registers it. Main thread only.
    func download(_ item: CoreDownload, completion: ((Result<Void, Error>) -> Void)? = nil) {
        if let completion { waiters[item.id, default: []].append(completion) }
        guard !downloading.contains(item.id) else { return }
        downloading.insert(item.id)
        downloadErrors[item.id] = nil
        Task.detached { [self] in
            var failure: Error?
            do { try await self.fetchAndInstall(item) } catch { failure = error }
            let outcome = failure
            DispatchQueue.main.async {
                self.refresh {
                    self.downloading.remove(item.id)
                    let result: Result<Void, Error> = outcome.map { Result<Void, Error>.failure($0) } ?? Result<Void, Error>.success(())
                    if let outcome { self.downloadErrors[item.id] = outcome.localizedDescription }
                    let callbacks = self.waiters.removeValue(forKey: item.id) ?? []
                    callbacks.forEach { $0(result) }
                }
            }
        }
    }

    private func fetchAndInstall(_ item: CoreDownload) async throws {
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(from: item.url)
        } catch {
            throw CoreError.installFailed("could not reach \(item.url.host ?? "the server"): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CoreError.installFailed("the server answered HTTP \(http.statusCode) for \(item.archiveName)")
        }
        let work = AppPaths.root.appendingPathComponent("Downloads/\(UUID().uuidString)", isDirectory: true)
        let output = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent(item.archiveName)
        try FileManager.default.moveItem(at: temporary, to: archive)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, output.path]
        let pipe = Pipe()
        unzip.standardError = pipe
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CoreError.installFailed("the download could not be unzipped. \(text)")
        }
        var dylib: URL?
        if let walker = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.pathExtension == "dylib" { dylib = file; break }
        }
        guard let dylib else { throw CoreError.installFailed("the download did not contain a .dylib core") }
        try install(from: dylib)
    }

    static func probe(_ url: URL) -> CoreInfo? {
        guard let library = try? CoreLibrary(url: url) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        library.symbols.getSystemInfo(raw)
        func string(_ offset: Int) -> String? {
            raw.load(fromByteOffset: offset, as: UnsafePointer<CChar>?.self).map { String(cString: $0) }
        }
        guard let name = string(0) else { return nil }
        let extensions = (string(16) ?? "").split(separator: "|").map { $0.lowercased() }
        return CoreInfo(
            url: url, name: name, version: string(8) ?? "",
            extensions: extensions,
            needsFullPath: raw.load(fromByteOffset: 24, as: Bool.self))
    }

    /// The installed core for a system, matched by the core's file name (e.g. snes9x_libretro.dylib).
    func core(for system: GameSystem) -> CoreInfo? {
        cores.first { info in
            !info.fileName.contains("_hw") && system.coreKeys.contains { info.fileName.contains($0) }
        }
    }

    /// Copies a core the user chose into Application Support, clears the download quarantine flag
    /// and ad-hoc signs the copy (Apple Silicon refuses to load unsigned code).
    func install(from source: URL) throws {
        let destination = AppPaths.coresDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw CoreError.installFailed(error.localizedDescription)
        }
        removexattr(destination.path, "com.apple.quarantine", 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: destination)
            throw CoreError.installFailed("could not run codesign: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: destination)
            throw CoreError.installFailed("codesign failed: \(output)")
        }
        guard Self.probe(destination) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw CoreError.installFailed("the file is not a libretro core for this Mac (arm64/x86_64 must match the app).")
        }
        refresh()
    }

    func remove(_ info: CoreInfo) {
        if info.url.deletingLastPathComponent().standardizedFileURL == AppPaths.coresDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: info.url)
        }
        refresh()
    }
}
