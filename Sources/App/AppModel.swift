import AppKit
import Foundation
import SwiftUI

enum ScaleMode: String, CaseIterable, Identifiable {
    case fit, integer
    var id: String { rawValue }
    var label: String { self == .fit ? "Fit window" : "Integer scale" }
}

enum VideoFilter: String, CaseIterable, Identifiable {
    case sharp, smooth
    var id: String { rawValue }
    var label: String { self == .sharp ? "Sharp (pixels)" : "Smooth" }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var scaleMode: ScaleMode { didSet { defaults.set(scaleMode.rawValue, forKey: "scaleMode") } }
    @Published var filter: VideoFilter { didSet { defaults.set(filter.rawValue, forKey: "filter") } }
    @Published var crtEffect: Bool { didSet { defaults.set(crtEffect, forKey: "crtEffect") } }
    @Published var volume: Float { didSet { defaults.set(volume, forKey: "volume") } }

    init() {
        scaleMode = ScaleMode(rawValue: defaults.string(forKey: "scaleMode") ?? "") ?? .fit
        filter = VideoFilter(rawValue: defaults.string(forKey: "filter") ?? "") ?? .sharp
        crtEffect = defaults.bool(forKey: "crtEffect")
        volume = defaults.object(forKey: "volume") == nil ? 0.8 : defaults.float(forKey: "volume")
    }
}

struct AppAlert: Identifiable {
    enum Action { case openCoreSettings, openBIOSSettings }
    let id = UUID()
    let title: String
    let message: String
    var details: String?
    var action: Action?
}

enum SettingsTab: String { case library, controllers, video, cores, data }

/// One running game: owns the engine and the state the play window shows.
final class PlaySession: ObservableObject, Identifiable {
    let id = UUID()
    let game: Game
    let system: GameSystem
    let core: CoreInfo
    let engine: EmulatorEngine

    @Published var paused = false { didSet { engine.setPaused(paused) } }
    @Published var speed = 1.0 { didSet { engine.setSpeed(speed) } }
    @Published var currentSlot = 1
    @Published private(set) var slots: [SlotInfo] = []
    @Published var toast: String?
    private var toastWork: DispatchWorkItem?

    init(game: Game, system: GameSystem, core: CoreInfo, engine: EmulatorEngine) {
        self.game = game
        self.system = system
        self.core = core
        self.engine = engine
        refreshSlots()
    }

    func refreshSlots() { slots = SaveStates.info(game: game.id) }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func saveState(slot: Int) {
        let gameID = game.id
        let box = engine.box
        engine.perform({ try $0.serialize() }) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    try SaveStates.write(state: data, thumbnail: SaveStates.thumbnailPNG(from: box.snapshot()), game: gameID, slot: slot)
                    self?.currentSlot = slot
                    self?.refreshSlots()
                    self?.showToast("Saved to slot \(slot)")
                } catch {
                    self?.showToast("Could not write the save state: \(error.localizedDescription)")
                }
            case .failure:
                self?.showToast("This core cannot save states")
            }
        }
    }

    func loadState(slot: Int) {
        guard let data = SaveStates.read(game: game.id, slot: slot) else {
            showToast("Slot \(slot) is empty")
            return
        }
        engine.perform({ try $0.unserialize(data) }) { [weak self] result in
            switch result {
            case .success:
                self?.currentSlot = slot
                self?.showToast("Loaded slot \(slot)")
            case .failure:
                self?.showToast("Slot \(slot) could not be loaded")
            }
        }
    }

    func quickSave() { saveState(slot: currentSlot) }
    func quickLoad() { loadState(slot: currentSlot) }

    func reset() {
        engine.reset()
        showToast("Reset")
    }

    func stop() {
        engine.stop()
        InputMapper.shared.activeSystemID = nil
        InputMapper.shared.releaseAll()
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    let library = GameLibrary()
    let cores = CoreCatalog.shared
    let settings = AppSettings.shared
    let input = InputMapper.shared

    @Published var session: PlaySession?
    @Published var alert: AppAlert?
    @Published var isStarting = false
    @Published var statusText: String?
    @Published var settingsTab: SettingsTab = .library

    private var started = false

    /// Called once from the first window.
    func start() {
        guard !started else { return }
        started = true
        CrashGuard.install()
        input.start()
        input.onHotkey = { [weak self] key in
            guard let session = self?.session else { return }
            switch key {
            case .quickSave: session.quickSave()
            case .quickLoad: session.quickLoad()
            case .pause: session.paused.toggle()
            }
        }
        cores.refresh()
        library.rescanWatched()
        if let report = CrashGuard.takePendingReport() {
            alert = AppAlert(
                title: "A core crashed",
                message: "The emulator core stopped unexpectedly during the last session, and Retro Console had to close. You are back in the library; your save states and battery saves are untouched.",
                details: report)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.session == nil { self?.library.rescanWatched() }
        }
    }

    /// Set by the root view; opens one of the app's own windows ("settings", "about").
    var openWindowAction: ((String) -> Void)?

    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        openWindowAction?("settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    func play(_ game: Game) {
        guard session == nil, !isStarting else { return }
        guard let system = game.system else {
            alert = AppAlert(title: "File not recognized", message: "Retro Console does not know which system “\(game.title)” belongs to.")
            return
        }
        guard FileManager.default.fileExists(atPath: game.path) else {
            alert = AppAlert(title: "Game file not found",
                             message: "“\(game.title)” is no longer at\n\(game.path)\n\nMove it back, or remove it from the library and add it again.")
            return
        }
        guard let core = cores.core(for: system) else {
            if let item = CoreCatalog.download(for: system) {
                // Missing core: fetch it, then start the game.
                isStarting = true
                statusText = "Downloading \(item.name)…"
                cores.download(item) { [weak self] result in
                    guard let self else { return }
                    self.isStarting = false
                    self.statusText = nil
                    switch result {
                    case .success: self.play(game)
                    case .failure(let error):
                        self.alert = AppAlert(
                            title: "Could not download \(item.name)",
                            message: "\(system.name) games need the \(item.name) core, and it could not be downloaded. Check your internet connection, or install a core file yourself in Settings → Cores & BIOS.",
                            details: error.localizedDescription, action: .openCoreSettings)
                    }
                }
                return
            }
            alert = AppAlert(
                title: "Core missing for \(system.shortName)",
                message: "\(system.name) games are played by the \(system.coreName) libretro core, which is not installed. Retro Console does not include emulator cores; install a build of \(system.coreName) (a *_libretro.dylib file) in Settings → Cores.",
                action: .openCoreSettings)
            return
        }
        if let files = BIOSManager.missingRequirement(for: system) {
            alert = AppAlert(
                title: "BIOS needed for \(system.shortName)",
                message: "\(system.name) needs one of these files from your own console: \(files.joined(separator: ", ")). Choose it in Settings → Cores & BIOS. Other systems keep working without it.",
                action: .openBIOSSettings)
            return
        }

        let engine = EmulatorEngine(coreURL: core.url, gameURL: game.url, gameID: game.id, systemName: system.name, input: input.state)
        isStarting = true
        input.releaseAll()
        engine.start { [weak self] result in
            guard let self else { return }
            self.isStarting = false
            switch result {
            case .success:
                self.input.activeSystemID = system.id
                self.library.markPlayed(game)
                self.session = PlaySession(game: game, system: system, core: core, engine: engine)
            case .failure(let error):
                engine.stop()
                var message = error.localizedDescription
                var action: AppAlert.Action?
                if case CoreError.gameRejected = error, case .anyOf = system.bios {
                    message += "\n\nThis system needs a BIOS file; check Settings → Cores & BIOS."
                    action = .openBIOSSettings
                }
                self.alert = AppAlert(title: "Could not start “\(game.title)”", message: message, details: "Core: \(core.name) \(core.version)\nFile: \(core.url.lastPathComponent)", action: action)
            }
        }
    }

    func closeSession() {
        guard let session else { return }
        session.stop()
        self.session = nil
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.root])
    }
}
