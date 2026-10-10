import Combine
import Foundation
import CryptoKit

struct Game: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var path: String
    var systemID: String
    var addedAt: Date
    var lastPlayed: Date?
    var playCount: Int
    var favorite: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var system: GameSystem? { SystemCatalog.system(id: systemID) }
}

enum TitleNormalizer {
    /// "Super Game (USA) [!].sfc" → "Super Game"
    static func title(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = name.range(of: open), let end = name.range(of: close, range: start.upperBound..<name.endIndex) {
                name.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        name = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}

struct ScanResult {
    var games: [Game] = []
    var unrecognized = 0
}

enum LibraryScanner {
    static func gameID(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads (never copies) files and folders. Files referenced by a .cue or .m3u are part of
    /// that disc and are not listed on their own.
    static func scan(_ urls: [URL]) -> ScanResult {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: options) {
                    for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        files.append(file)
                    }
                }
            } else {
                files.append(url)
            }
        }

        var claimed = Set<String>()
        for file in files {
            let ext = file.pathExtension.lowercased()
            let names: [String]
            if ext == "cue" { names = SystemCatalog.referencedFiles(inCue: file) }
            else if ext == "m3u" { names = SystemCatalog.referencedFiles(inM3U: file) }
            else { continue }
            for name in names {
                claimed.insert(file.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.path)
            }
        }

        var result = ScanResult()
        var seen = Set<String>()
        for file in files {
            let path = file.standardizedFileURL.path
            let ext = file.pathExtension.lowercased()
            guard SystemCatalog.knownExtensions.contains(ext), !claimed.contains(path), seen.insert(path).inserted else { continue }
            guard let system = SystemCatalog.identify(file) else {
                result.unrecognized += 1
                continue
            }
            result.games.append(Game(
                id: gameID(for: path), title: TitleNormalizer.title(from: file), path: path,
                systemID: system.id, addedAt: Date(), lastPlayed: nil, playCount: 0, favorite: false))
        }
        return result
    }
}

/// The game library: a JSON file in Application Support. Games stay where the user has them.
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published private(set) var watchedFolders: [String] = []
    @Published private(set) var isScanning = false
    @Published var statusMessage: String?

    private struct Store: Codable {
        var games: [Game]
        var watchedFolders: [String]
    }

    init() { load() }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let store = try? decoder.decode(Store.self, from: data) {
            games = store.games
            watchedFolders = store.watchedFolders
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Store(games: games, watchedFolders: watchedFolders)) {
            try? data.write(to: AppPaths.libraryFile, options: .atomic)
        }
    }

    // MARK: Adding

    /// Files or folders from a drop or an open panel.
    func add(urls: [URL]) {
        scan(urls, pruneUnder: [])
    }

    func addWatchedFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !watchedFolders.contains(path) { watchedFolders.append(path) }
        save()
        scan([url], pruneUnder: [path])
    }

    func removeWatchedFolder(_ path: String) {
        watchedFolders.removeAll { $0 == path }
        save()
    }

    func rescanWatched() {
        guard !watchedFolders.isEmpty else { return }
        scan(watchedFolders.map { URL(fileURLWithPath: $0) }, pruneUnder: watchedFolders)
    }

    private func scan(_ urls: [URL], pruneUnder folders: [String]) {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async {
            let result = LibraryScanner.scan(urls)
            DispatchQueue.main.async {
                self.merge(result, pruneUnder: folders)
                self.isScanning = false
            }
        }
    }

    private func merge(_ result: ScanResult, pruneUnder folders: [String]) {
        var added = 0
        var index = Dictionary(games.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for game in result.games {
            if let existing = index[game.id] {
                games[existing].systemID = game.systemID
            } else {
                games.append(game)
                index[game.id] = games.count - 1
                added += 1
            }
        }
        // A rescan of a watched folder forgets games whose files were deleted from it.
        var removed = 0
        if !folders.isEmpty {
            let before = games.count
            games.removeAll { game in
                folders.contains { game.path.hasPrefix($0 + "/") } && !FileManager.default.fileExists(atPath: game.path)
            }
            removed = before - games.count
        }
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added) game\(added == 1 ? "" : "s")") }
        if removed > 0 { parts.append("removed \(removed) missing") }
        if result.unrecognized > 0 { parts.append("\(result.unrecognized) file\(result.unrecognized == 1 ? "" : "s") not recognized") }
        statusMessage = parts.isEmpty ? (result.games.isEmpty ? "No games found" : "Library is up to date") : parts.joined(separator: " · ")
        save()
    }

    // MARK: Editing

    func fileExists(_ game: Game) -> Bool { FileManager.default.fileExists(atPath: game.path) }

    func toggleFavorite(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].favorite.toggle()
        save()
    }

    func markPlayed(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].lastPlayed = Date()
        games[i].playCount += 1
        save()
    }

    /// Removes the entry only. The game file and its save data are untouched.
    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        save()
    }

    /// Clears the list of games and watched folders. Game files, save states and battery saves stay.
    func clear() {
        games = []
        watchedFolders = []
        statusMessage = nil
        save()
    }
}
