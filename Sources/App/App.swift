import SwiftUI

@main
struct RetroConsoleApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.library)
                .environmentObject(model.cores)
                .environmentObject(model.settings)
                .environmentObject(model.input)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1000, height: 680)
        .commands { AppCommands(model: model) }

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.library)
                .environmentObject(model.cores)
                .environmentObject(model.settings)
                .environmentObject(model.input)
        }
        .windowResizability(.contentSize)

        Window("About Retro Console", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Retro Console") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings(tab: .library) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Games…") { LibraryActions.chooseGames(model.library) }
                .keyboardShortcut("o")
            Button("Add Folder…") { LibraryActions.chooseFolder(model.library, watch: false) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Game") {
            Button(model.session?.paused == true ? "Resume" : "Pause") { model.session?.paused.toggle() }
                .keyboardShortcut("p")
                .disabled(model.session == nil)
            Button("Reset") { model.session?.reset() }
                .keyboardShortcut("r")
                .disabled(model.session == nil)
            Divider()
            Button("Quick Save") { model.session?.quickSave() }
                .keyboardShortcut("s")
                .disabled(model.session == nil)
            Button("Quick Load") { model.session?.quickLoad() }
                .keyboardShortcut("l")
                .disabled(model.session == nil)
            Divider()
            Button("Back to Library") { model.closeSession() }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(model.session == nil)
        }
    }
}

enum LibraryActions {
    static func chooseGames(_ library: GameLibrary) {
        let panel = NSOpenPanel()
        panel.title = "Add Games"
        panel.message = "Choose game files or folders. They stay where they are; nothing is copied."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { library.add(urls: panel.urls) }
    }

    static func chooseFolder(_ library: GameLibrary, watch: Bool) {
        let panel = NSOpenPanel()
        panel.title = watch ? "Watch Folder" : "Add Folder"
        panel.message = watch ? "Games in this folder are added now and whenever the app opens or becomes active." : "All games found in this folder are added once."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = !watch
        guard panel.runModal() == .OK else { return }
        if watch { panel.urls.forEach { library.addWatchedFolder($0) } } else { library.add(urls: panel.urls) }
    }
}
