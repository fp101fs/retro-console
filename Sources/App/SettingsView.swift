import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }.tag(SettingsTab.library)
            ControllerSettings().tabItem { Label("Controllers", systemImage: "gamecontroller") }.tag(SettingsTab.controllers)
            VideoSettings().tabItem { Label("Video", systemImage: "display") }.tag(SettingsTab.video)
            CoreSettings().tabItem { Label("Cores & BIOS", systemImage: "puzzlepiece.extension") }.tag(SettingsTab.cores)
            DataSettings().tabItem { Label("Data", systemImage: "folder") }.tag(SettingsTab.data)
        }
        .frame(width: 640, height: 520)
    }
}

private struct LibrarySettings: View {
    @EnvironmentObject var library: GameLibrary
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Watched folders") {
                if library.watchedFolders.isEmpty {
                    Text("No folders are watched. Watched folders are scanned when the app opens or becomes active.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.watchedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { library.removeWatchedFolder(path) }
                    }
                }
                HStack {
                    Button("Add Folder…") { LibraryActions.chooseFolder(library, watch: true) }
                    Button("Rescan Now") { library.rescanWatched() }.disabled(library.watchedFolders.isEmpty)
                    if library.isScanning { ProgressView().controlSize(.small) }
                    if let status = library.statusMessage { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Library") {
                Text("\(library.games.count) games. Games stay where you keep them; Retro Console only remembers where they are.")
                    .foregroundStyle(.secondary)
                Button("Clear Library…", role: .destructive) { confirmClear = true }
                    .disabled(library.games.isEmpty && library.watchedFolders.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the whole library?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Library", role: .destructive) { library.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every game entry and watched folder from the list. Your game files, save states and battery saves are not deleted.")
        }
    }
}

private struct VideoSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Picker("Scaling", selection: $settings.scaleMode) {
                ForEach(ScaleMode.allCases) { Text($0.label).tag($0) }
            }
            Text("Integer scale keeps every pixel the same size (the largest whole multiple that fits). Fit window fills the window at the correct aspect ratio.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Filter", selection: $settings.filter) {
                ForEach(VideoFilter.allCases) { Text($0.label).tag($0) }
            }
            Toggle("CRT scanlines", isOn: $settings.crtEffect)
            Text("A small Metal shader darkens the gaps between scanlines. Turn it off for a clean picture.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Volume")
                Slider(value: Binding(get: { Double(settings.volume) }, set: { settings.volume = Float($0) }), in: 0...1)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Data folder") {
                Text(AppPaths.root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Reveal in Finder") { model.revealDataFolder() }
                Text("Holds the library (library.json), installed cores, BIOS files you chose, save states and battery saves. Game files are never copied or modified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Cores & BIOS

private struct CoreSettings: View {
    @EnvironmentObject var cores: CoreCatalog
    @State private var message: String?
    @State private var refreshTick = 0

    var body: some View {
        Form {
            Section("Emulator cores") {
                Text("Retro Console plays games with libretro cores: Snes9x (SNES), Genesis Plus GX (Genesis, Master System, Game Gear, SG-1000, Sega CD), mGBA (Game Boy, Color, Advance) and Beetle PSX (PlayStation). No cores are included. Press Download to fetch a core's published build from buildbot.libretro.com (only when you ask, or when you open a game that needs it), or install your own *_libretro.dylib. Each core is ad-hoc signed on this Mac so macOS will load it.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(CoreDownload.all) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text(item.systems).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if cores.downloading.contains(item.id) {
                                ProgressView().controlSize(.small)
                                Text("Downloading…").font(.caption)
                            } else if let core = cores.installed(item) {
                                Label("Installed \(core.version)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green).font(.caption)
                                Button("Update") { cores.download(item) }
                                if core.url.deletingLastPathComponent().standardizedFileURL == AppPaths.coresDirectory.standardizedFileURL {
                                    Button("Remove") { cores.remove(core) }
                                }
                            } else {
                                Button { cores.download(item) } label: { Label("Download", systemImage: "arrow.down.circle.fill") }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if let error = cores.downloadErrors[item.id] {
                            Text("Download failed: \(error)").font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                ForEach(cores.cores.filter { core in !CoreDownload.all.contains { core.fileName.contains($0.id) } }) { core in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(core.name) \(core.version)")
                            Text(core.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if core.url.deletingLastPathComponent().standardizedFileURL == AppPaths.coresDirectory.standardizedFileURL {
                            Button("Remove") { cores.remove(core) }
                        }
                    }
                }
                HStack {
                    Button("Install Core File…") { installCore() }
                    Button("Show Cores Folder") { NSWorkspace.shared.open(AppPaths.coresDirectory) }
                    Button("Rescan") { cores.refresh() }
                    if cores.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
            }
            Section("Systems") {
                ForEach(SystemCatalog.all) { system in
                    HStack {
                        Image(systemName: system.symbol).foregroundStyle(system.color).frame(width: 22)
                        Text(system.name)
                        Spacer()
                        if let core = cores.core(for: system) {
                            Label(core.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        } else {
                            Label("\(system.coreName) not installed", systemImage: "xmark.circle").foregroundStyle(.orange).font(.caption)
                        }
                    }
                }
            }
            Section("BIOS / firmware") {
                Text("Choose files from your own consoles. They are copied into the app's System folder, never uploaded. Systems without a requirement work without them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(SystemCatalog.all.filter { BIOSManager.files(for: $0).names.isEmpty == false }) { system in
                    let info = BIOSManager.files(for: system)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(system.name + (info.required ? " — needs one of:" : " — optional:")).font(.subheadline.bold())
                        ForEach(info.names, id: \.self) { name in
                            HStack {
                                Image(systemName: BIOSManager.isPresent(name) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(BIOSManager.isPresent(name) ? Color.green : Color.secondary)
                                Text(name).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button("Choose…") { chooseBIOS(for: name) }
                                if BIOSManager.isPresent(name) {
                                    Button("Remove") { BIOSManager.remove(name); refreshTick += 1 }
                                }
                            }
                        }
                    }
                    .id("\(system.id)-\(refreshTick)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func installCore() {
        let panel = NSOpenPanel()
        panel.title = "Install Core"
        panel.message = "Choose a libretro core (*_libretro.dylib)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try cores.install(from: url)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func chooseBIOS(for name: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(name)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BIOSManager.install(url, as: name)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        refreshTick += 1
    }
}

// MARK: Controllers

private struct ControllerSettings: View {
    @EnvironmentObject var input: InputMapper
    @State private var systemID = SystemCatalog.all[0].id
    @State private var waiting: (RetroButton, Bool)?   // (button, isKeyboard)

    private var system: GameSystem { SystemCatalog.system(id: systemID) ?? SystemCatalog.all[0] }
    private var mapping: ButtonMapping { input.mapping(for: systemID) }

    var body: some View {
        Form {
            Section("Connected controllers") {
                if input.controllers.isEmpty {
                    Label("No controller connected — keyboard controls are used.", systemImage: "keyboard").foregroundStyle(.secondary)
                }
                ForEach(input.controllers) { controller in
                    Label("\(controller.name) (\(controller.kind))", systemImage: "gamecontroller.fill")
                }
                Text("Xbox, DualShock/DualSense, 8BitDo and other pads supported by macOS are set up automatically (bottom button = B, right = A). The first connected pad is Player 1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Button mapping") {
                Picker("System", selection: $systemID) {
                    ForEach(SystemCatalog.all) { Text($0.name).tag($0.id) }
                }
                .onChange(of: systemID) { _ in cancelCapture() }
                ForEach(system.buttons) { button in
                    HStack {
                        Text(button.label).frame(width: 90, alignment: .leading)
                        Spacer()
                        mapButton(button, keyboard: false)
                        mapButton(button, keyboard: true)
                    }
                }
                HStack {
                    Button("Reset to Defaults") { cancelCapture(); input.resetMapping(for: systemID) }
                    if waiting != nil { Text("Press a button or key… (Esc cancels)").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { cancelCapture() }
    }

    private func mapButton(_ button: RetroButton, keyboard: Bool) -> some View {
        let isWaiting = waiting?.0 == button && waiting?.1 == keyboard
        let title: String
        if isWaiting {
            title = keyboard ? "Press a key…" : "Press a pad button…"
        } else if keyboard {
            let keys = mapping.keyboard.filter { $0.value == button }.keys.compactMap { Int($0) }.sorted().map(ButtonMapping.keyName)
            title = keys.isEmpty ? "Key: —" : "Key: " + keys.joined(separator: ", ")
        } else {
            let pads = PadControl.allCases.filter { mapping.pad[$0.rawValue] == button }.map(\.label)
            title = pads.isEmpty ? "Pad: —" : "Pad: " + pads.joined(separator: ", ")
        }
        return Button(title) { beginCapture(button, keyboard: keyboard) }
            .buttonStyle(.bordered)
            .tint(isWaiting ? Color.orange : Color.accentColor)
            .frame(maxWidth: 230, alignment: .trailing)
            .lineLimit(1)
    }

    private func beginCapture(_ button: RetroButton, keyboard: Bool) {
        waiting = (button, keyboard)
        input.captureHandler = { capture in
            DispatchQueue.main.async { handle(capture, for: button, keyboard: keyboard) }
        }
    }

    /// A press of the wrong kind (pad while waiting for a key) is ignored; Esc cancels.
    private func handle(_ capture: InputCapture, for button: RetroButton, keyboard: Bool) {
        guard waiting != nil else { return }
        var updated = input.mapping(for: systemID)
        switch capture {
        case .key(let code):
            if code == 53 { cancelCapture(); return }
            guard keyboard else { return }
            updated.keyboard = updated.keyboard.filter { $0.value != button }
            updated.keyboard[String(code)] = button
        case .pad(let control):
            guard !keyboard else { return }
            updated.pad = updated.pad.filter { $0.value != button }
            updated.pad[control.rawValue] = button
        }
        input.setMapping(updated, for: systemID)
        cancelCapture()
    }

    private func cancelCapture() {
        waiting = nil
        input.captureHandler = nil
    }
}
