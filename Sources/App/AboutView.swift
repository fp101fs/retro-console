import SwiftUI

struct LicenseEntry: Identifiable {
    let id: String
    let name: String
    let license: String
    let credit: String
    let source: String
    /// Path of the full license text below Assets/codename/ (downloaded into the app bundle at build time).
    let assetPath: String?
}

enum LicenseLibrary {
    static let repository = "https://github.com/Lonkins/CODENAME"

    static let entries: [LicenseEntry] = [
        LicenseEntry(
            id: "app", name: "CODENAME (host application code)", license: "GPL-3.0-or-later",
            credit: "Based on Lonkins/CODENAME: the libretro host, Metal presentation, audio resampling and pacing, input and library logic are ported from it.",
            source: repository, assetPath: "LICENSE"),
        LicenseEntry(
            id: "libretro", name: "libretro API (libretro.h)", license: "MIT-style",
            credit: "The libretro API is by the libretro / RetroArch team (libretro-common). The structures this app uses are restated in Swift.",
            source: "https://github.com/libretro/libretro-common", assetPath: nil),
        LicenseEntry(
            id: "genesis", name: "Genesis Plus GX", license: "Non-commercial (own license)",
            credit: "Copyright © 1998–2003 Charles MacDonald; © 2007–2026 Eke-Eke; portions Nicola Salmoria and the MAME team. May not be sold or used in a commercial product or activity.",
            source: "https://github.com/libretro/Genesis-Plus-GX", assetPath: "App/CoreLicences/genesis_plus_gx.txt"),
        LicenseEntry(
            id: "snes9x", name: "Snes9x", license: "Non-commercial (own license)",
            credit: "Copyright © 1996–2002 Gary Henderson and Jerremy Koot, and the many Snes9x contributors listed in the license, including BearOso and OV2.",
            source: "https://github.com/libretro/snes9x", assetPath: "App/CoreLicences/snes9x.txt"),
        LicenseEntry(
            id: "mgba", name: "mGBA", license: "MPL-2.0",
            credit: "Copyright © Jeffrey Pfau and mGBA contributors, with the bundled dependencies named in its license.",
            source: "https://github.com/libretro/mgba", assetPath: "App/CoreLicences/mgba.txt"),
        LicenseEntry(
            id: "beetle", name: "Beetle PSX (mednafen_psx)", license: "GPL-2.0",
            credit: "Based on Mednafen by the Mednafen Team and the libretro contributors to Beetle PSX.",
            source: "https://github.com/libretro/beetle-psx-libretro", assetPath: "App/CoreLicences/beetle_psx.txt"),
    ]

    static func fullText(for entry: LicenseEntry) -> String? {
        guard let path = entry.assetPath,
            let base = Bundle.main.resourceURL?.appendingPathComponent("Assets/codename", isDirectory: true) else { return nil }
        return try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }
}

struct AboutView: View {
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Retro Console").font(.title.bold())
                    Text("A retro game player for your own game files").foregroundStyle(.secondary)
                }
            }
            Text("You must own the games you play.")
                .font(.headline)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            Text("Based on \(LicenseLibrary.repository), GPL-3.0-or-later. Retro Console contains no games, BIOS files, firmware or box art, and downloads none. Games stay where you keep them. Emulation is done by separate libretro cores, which the app downloads from buildbot.libretro.com only when you press Download or open a game that needs one; each core is a separate work under its own license, listed below.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(LicenseLibrary.entries) { entry in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(entry.id) },
                            set: { if $0 { expanded.insert(entry.id) } else { expanded.remove(entry.id) } })
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.credit).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Text(entry.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if expanded.contains(entry.id) {
                                    if let text = LicenseLibrary.fullText(for: entry) {
                                        ScrollView {
                                            Text(text).font(.system(size: 10, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(height: 180)
                                        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                    } else if entry.assetPath != nil {
                                        Text("The full license text is not available in this build. It is in the project repository at \(entry.assetPath ?? "") and in each core's own source.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Text(entry.name).font(.headline)
                                Spacer()
                                Text(entry.license).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            Text("Genesis Plus GX and Snes9x licenses forbid commercial use; do not sell or bundle those cores with a paid product.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }
}
