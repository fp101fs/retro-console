import AppKit
import Foundation

struct SlotInfo: Identifiable {
    let slot: Int
    let date: Date?
    let thumbnail: NSImage?
    var id: Int { slot }
    var isEmpty: Bool { date == nil }
}

/// Save states (4 slots with a screenshot) and battery saves, all under
/// Application Support/Games/<game id>/ — never beside the user's game file.
enum SaveStates {
    static let slotCount = 4

    static func stateURL(game: String, slot: Int) -> URL {
        AppPaths.dataDirectory(forGame: game).appendingPathComponent("slot\(slot).state")
    }

    static func thumbnailURL(game: String, slot: Int) -> URL {
        AppPaths.dataDirectory(forGame: game).appendingPathComponent("slot\(slot).png")
    }

    static func batteryURL(game: String) -> URL {
        AppPaths.dataDirectory(forGame: game).appendingPathComponent("battery.srm")
    }

    static func write(state: Data, thumbnail: Data?, game: String, slot: Int) throws {
        try state.write(to: stateURL(game: game, slot: slot), options: .atomic)
        if let thumbnail { try? thumbnail.write(to: thumbnailURL(game: game, slot: slot), options: .atomic) }
    }

    static func read(game: String, slot: Int) -> Data? {
        try? Data(contentsOf: stateURL(game: game, slot: slot))
    }

    static func info(game: String) -> [SlotInfo] {
        (1...slotCount).map { slot in
            let url = stateURL(game: game, slot: slot)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let image = date == nil ? nil : NSImage(contentsOf: thumbnailURL(game: game, slot: slot))
            return SlotInfo(slot: slot, date: date, thumbnail: image)
        }
    }

    static func delete(game: String, slot: Int) {
        try? FileManager.default.removeItem(at: stateURL(game: game, slot: slot))
        try? FileManager.default.removeItem(at: thumbnailURL(game: game, slot: slot))
    }

    /// PNG of a BGRA frame, used as the slot's screenshot.
    static func thumbnailPNG(from frame: VideoFrame?) -> Data? {
        guard let frame else { return nil }
        var bytes = frame.bytes
        let image: CGImage? = bytes.withUnsafeMutableBytes { buffer in
            let space = CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(
                data: buffer.baseAddress, width: frame.width, height: frame.height,
                bitsPerComponent: 8, bytesPerRow: frame.width * 4, space: space, bitmapInfo: info) else { return nil }
            return context.makeImage()
        }
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
