import Foundation
import CryptoKit
import SwiftUI

enum BIOSRule {
    case none
    case optional([String])
    case anyOf([String])
}

struct GameSystem: Identifiable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let extensions: [String]
    /// Substrings of the core's file name that select its core (e.g. "snes9x" for snes9x_libretro.dylib).
    let coreKeys: [String]
    let coreName: String
    let bios: BIOSRule
    let buttons: [RetroButton]
    let symbol: String
    let color: Color

    static func == (lhs: GameSystem, rhs: GameSystem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private let dpad: [RetroButton] = [.up, .down, .left, .right]

enum SystemCatalog {
    // Cores named by the original project: Snes9x, Genesis Plus GX, mGBA, Beetle PSX.
    static let all: [GameSystem] = [
        GameSystem(id: "snes", name: "Super Nintendo", shortName: "SNES",
                   extensions: ["smc", "sfc", "swc", "fig", "bs", "st"],
                   coreKeys: ["snes9x"], coreName: "Snes9x", bios: .none,
                   buttons: dpad + [.b, .a, .y, .x, .l, .r, .select, .start],
                   symbol: "gamecontroller", color: Color(red: 0.45, green: 0.35, blue: 0.75)),
        GameSystem(id: "genesis", name: "Sega Genesis / Mega Drive", shortName: "Genesis",
                   extensions: ["md", "gen", "smd", "bin"],
                   coreKeys: ["genesis_plus_gx"], coreName: "Genesis Plus GX", bios: .none,
                   buttons: dpad + [.b, .a, .y, .x, .l, .r, .start],
                   symbol: "gamecontroller.fill", color: Color(red: 0.15, green: 0.35, blue: 0.75)),
        GameSystem(id: "sms", name: "Sega Master System", shortName: "Master System",
                   extensions: ["sms"],
                   coreKeys: ["genesis_plus_gx"], coreName: "Genesis Plus GX", bios: .none,
                   buttons: dpad + [.b, .a, .start],
                   symbol: "gamecontroller", color: Color(red: 0.8, green: 0.2, blue: 0.2)),
        GameSystem(id: "gamegear", name: "Sega Game Gear", shortName: "Game Gear",
                   extensions: ["gg"],
                   coreKeys: ["genesis_plus_gx"], coreName: "Genesis Plus GX", bios: .none,
                   buttons: dpad + [.b, .a, .start],
                   symbol: "gamecontroller", color: Color(red: 0.2, green: 0.55, blue: 0.5)),
        GameSystem(id: "sg1000", name: "Sega SG-1000", shortName: "SG-1000",
                   extensions: ["sg"],
                   coreKeys: ["genesis_plus_gx"], coreName: "Genesis Plus GX", bios: .none,
                   buttons: dpad + [.b, .a],
                   symbol: "gamecontroller", color: Color(red: 0.6, green: 0.4, blue: 0.2)),
        GameSystem(id: "segacd", name: "Sega CD / Mega-CD", shortName: "Sega CD",
                   extensions: ["cue", "iso", "chd", "bin", "m3u"],
                   coreKeys: ["genesis_plus_gx"], coreName: "Genesis Plus GX",
                   bios: .anyOf(["bios_CD_U.bin", "bios_CD_E.bin", "bios_CD_J.bin"]),
                   buttons: dpad + [.b, .a, .y, .x, .l, .r, .start],
                   symbol: "opticaldisc", color: Color(red: 0.1, green: 0.25, blue: 0.5)),
        GameSystem(id: "gb", name: "Game Boy", shortName: "Game Boy",
                   extensions: ["gb", "dmg", "sgb"],
                   coreKeys: ["mgba"], coreName: "mGBA", bios: .optional(["gb_bios.bin"]),
                   buttons: dpad + [.b, .a, .select, .start],
                   symbol: "gamecontroller", color: Color(red: 0.4, green: 0.55, blue: 0.3)),
        GameSystem(id: "gbc", name: "Game Boy Color", shortName: "GB Color",
                   extensions: ["gbc"],
                   coreKeys: ["mgba"], coreName: "mGBA", bios: .optional(["gbc_bios.bin"]),
                   buttons: dpad + [.b, .a, .select, .start],
                   symbol: "gamecontroller", color: Color(red: 0.55, green: 0.3, blue: 0.7)),
        GameSystem(id: "gba", name: "Game Boy Advance", shortName: "GBA",
                   extensions: ["gba"],
                   coreKeys: ["mgba"], coreName: "mGBA", bios: .optional(["gba_bios.bin"]),
                   buttons: dpad + [.b, .a, .l, .r, .select, .start],
                   symbol: "gamecontroller", color: Color(red: 0.3, green: 0.3, blue: 0.7)),
        GameSystem(id: "psx", name: "Sony PlayStation", shortName: "PlayStation",
                   extensions: ["cue", "bin", "iso", "img", "ccd", "pbp", "chd", "m3u", "exe"],
                   coreKeys: ["mednafen_psx", "beetle_psx", "beetle-psx"], coreName: "Beetle PSX",
                   bios: .anyOf(["scph5500.bin", "scph5501.bin", "scph5502.bin"]),
                   buttons: dpad + [.b, .a, .y, .x, .l, .r, .l2, .r2, .l3, .r3, .select, .start],
                   symbol: "opticaldisc.fill", color: Color(red: 0.35, green: 0.35, blue: 0.4)),
    ]

    static func system(id: String) -> GameSystem? { all.first { $0.id == id } }

    /// Extensions that at least one system plays.
    static let knownExtensions: Set<String> = Set(all.flatMap { $0.extensions })

    /// Identifies a file by extension and, where the extension is ambiguous (.bin, .cue, .iso,
    /// .chd, .m3u, .exe) or the core needs it, by the file's header. Returns nil if unrecognized.
    static func identify(_ url: URL) -> GameSystem? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "smc", "sfc", "swc", "fig", "bs", "st": return system(id: "snes")
        case "md", "gen", "smd": return system(id: "genesis")
        case "sms": return system(id: "sms")
        case "gg": return system(id: "gamegear")
        case "sg": return system(id: "sg1000")
        case "gba": return system(id: "gba")
        case "gb", "dmg", "sgb", "gbc":
            // Header byte 0x143: bit 7 set = Game Boy Color cartridge.
            if let flag = bytes(url, offset: 0x143, count: 1)?.first, flag & 0x80 != 0 { return system(id: "gbc") }
            return system(id: ext == "gbc" ? "gbc" : "gb")
        case "bin":
            // A Genesis cartridge carries "SEGA" in its header at 0x100; anything else must be a disc track.
            if let header = bytes(url, offset: 0x100, count: 4), header == Data("SEGA".utf8) { return system(id: "genesis") }
            return discSystem(url)
        case "exe":
            if let header = bytes(url, offset: 0, count: 8), header == Data("PS-X EXE".utf8) { return system(id: "psx") }
            return nil
        case "pbp", "ccd", "img":
            return ext == "img" ? discSystem(url) : system(id: "psx")
        case "chd":
            // Compressed discs cannot be sniffed without decoding; assume PlayStation.
            return system(id: "psx")
        case "cue", "iso", "m3u":
            return discSystem(url)
        default:
            return nil
        }
    }

    /// Disc images: the identification strings sit in the first sectors of track 1.
    private static func discSystem(_ url: URL) -> GameSystem? {
        let ext = url.pathExtension.lowercased()
        var target = url
        if ext == "cue" {
            guard let first = referencedFiles(inCue: url).first else { return nil }
            target = url.deletingLastPathComponent().appendingPathComponent(first)
        } else if ext == "m3u" {
            guard let first = referencedFiles(inM3U: url).first else { return nil }
            return identify(url.deletingLastPathComponent().appendingPathComponent(first))
        }
        guard let data = bytes(target, offset: 0, count: 128 * 1024) else { return nil }
        if data.range(of: Data("SEGADISCSYSTEM".utf8)) != nil { return system(id: "segacd") }
        if data.range(of: Data("PLAYSTATION".utf8)) != nil
            || data.range(of: Data("Sony Computer Entertainment".utf8)) != nil { return system(id: "psx") }
        return nil
    }

    static func referencedFiles(inCue url: URL) -> [String] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("FILE") else { continue }
            let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                names.append(String(parts[1]))
            } else {
                let tokens = trimmed.split(separator: " ")
                if tokens.count >= 2 { names.append(String(tokens[1])) }
            }
        }
        return names
    }

    static func referencedFiles(inM3U url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func bytes(_ url: URL, offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

// MARK: BIOS

/// BIOS / firmware files are supplied by the user and copied into Application Support/System,
/// the directory cores are told to look in. Nothing is bundled or downloaded.
enum BIOSManager {
    /// MD5 of the known PlayStation BIOS images (as documented by the Beetle PSX manual,
    /// from the original project's PSXBIOS.swift) → the file name the core looks for.
    static let knownPSX: [String: String] = [
        "8dd7d5296a650fac7319bce665a6a53c": "scph5500.bin",
        "490f666e1afb15b7362b406ed1cea246": "scph5501.bin",
        "32736f17079d0b2b7024407c39bd3050": "scph5502.bin",
    ]

    static func isPresent(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.systemDirectory.appendingPathComponent(fileName).path)
    }

    static func files(for system: GameSystem) -> (names: [String], required: Bool) {
        switch system.bios {
        case .none: return ([], false)
        case .optional(let names): return (names, false)
        case .anyOf(let names): return (names, true)
        }
    }

    /// Non-nil when the system cannot start because a required BIOS file is missing.
    static func missingRequirement(for system: GameSystem) -> [String]? {
        if case .anyOf(let names) = system.bios, !names.contains(where: isPresent) { return names }
        return nil
    }

    /// Copies a user-chosen file into the system directory. PlayStation images are recognized by
    /// digest and stored under the canonical name whatever the file was called.
    @discardableResult
    static func install(_ source: URL, as requested: String) throws -> String {
        var name = requested
        if knownPSX.values.contains(requested),
            let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
            let data = try? Data(contentsOf: source) {
            let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let canonical = knownPSX[digest] else {
                throw NSError(domain: "RetroConsole", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "That file is not a recognized PlayStation BIOS image (expected scph5500, scph5501 or scph5502)."])
            }
            name = canonical
        }
        let destination = AppPaths.systemDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }

    static func remove(_ fileName: String) {
        try? FileManager.default.removeItem(at: AppPaths.systemDirectory.appendingPathComponent(fileName))
    }
}
