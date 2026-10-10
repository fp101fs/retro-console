import Foundation

/// Every file the app writes lives under Application Support. Game files are
/// never copied, moved or written next to: only read from where the user keeps them.
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Retro Console", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
    static var crashReport: URL { root.appendingPathComponent("last-crash.txt") }
    /// User-installed libretro cores (.dylib).
    static var coresDirectory: URL { subdirectory("Cores") }
    /// BIOS / firmware files the user chose. Handed to cores as their "system directory".
    static var systemDirectory: URL { subdirectory("System") }
    static var gamesDirectory: URL { subdirectory("Games") }

    /// Cores shipped inside the app bundle (Contents/PlugIns), if any.
    static var bundledCoresDirectory: URL? { Bundle.main.builtInPlugInsURL }

    /// Per-game data: battery saves, save states, core-managed saves (memory cards).
    static func dataDirectory(forGame id: String) -> URL {
        let url = gamesDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func subdirectory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
