import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            if let session = model.session {
                PlayView(session: session)
            } else {
                LibraryView()
            }
            if model.isStarting {
                Color.black.opacity(0.45)
                ProgressView(model.statusText ?? "Starting core…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $model.alert) { alert in AlertSheet(alert: alert) }
        .onAppear { model.openWindowAction = { id in openWindow(id: id) } }
    }
}

struct AlertSheet: View {
    let alert: AppAlert
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
            Text(alert.message).fixedSize(horizontal: false, vertical: true)
            if let details = alert.details {
                Text("Details").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 110)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                if let action = alert.action {
                    Button(action == .openCoreSettings ? "Open Cores Settings" : "Open BIOS Settings") {
                        dismiss()
                        model.openSettings(tab: .cores)
                    }
                }
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

enum SidebarItem: Hashable {
    case all, favorites, recent
    case system(String)
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: GameLibrary
    @EnvironmentObject var cores: CoreCatalog

    @State private var selection: SidebarItem? = .all
    @State private var search = ""
    @AppStorage("libraryViewMode") private var viewMode = "grid"
    @State private var dropTargeted = false
    @State private var selectedGame: String?

    private var filtered: [Game] {
        var games = library.games
        switch selection ?? .all {
        case .all: break
        case .favorites: games = games.filter { $0.favorite }
        case .recent: games = Array(games.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(24))
        case .system(let id): games = games.filter { $0.systemID == id }
        }
        if !search.isEmpty { games = games.filter { $0.title.localizedCaseInsensitiveContains(search) } }
        if case .recent = selection ?? .all { return games }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            detail
        }
        .searchable(text: $search, prompt: "Search games")
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openSettings(tab: .cores) } label: { Label("Cores", systemImage: "puzzlepiece.extension") }
                    .help("Download and manage emulator cores")
                Button { model.openSettings(tab: .library) } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings")
                Picker("View", selection: $viewMode) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                Menu {
                    Button("Add Games…") { LibraryActions.chooseGames(library) }
                    Button("Add Folder…") { LibraryActions.chooseFolder(library, watch: false) }
                    Button("Watch Folder…") { LibraryActions.chooseFolder(library, watch: true) }
                    Divider()
                    Button("Rescan Watched Folders") { library.rescanWatched() }
                        .disabled(library.watchedFolders.isEmpty)
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Retro Console")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Games", systemImage: "square.grid.2x2").tag(SidebarItem.all)
                Label("Favorites", systemImage: "star.fill").tag(SidebarItem.favorites)
                Label("Recently Played", systemImage: "clock").tag(SidebarItem.recent)
            }
            Section("Systems") {
                ForEach(SystemCatalog.all.filter { system in library.games.contains { $0.systemID == system.id } }) { system in
                    HStack {
                        Label(system.shortName, systemImage: system.symbol)
                        Spacer()
                        if cores.core(for: system) == nil {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                .help("The \(system.coreName) core is not installed")
                        }
                        Text("\(library.games.filter { $0.systemID == system.id }.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.system(system.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if library.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Scanning…").font(.caption) }.padding(8)
            } else if let status = library.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if cores.cores.isEmpty && !library.games.isEmpty {
                HStack {
                    Image(systemName: "puzzlepiece.extension")
                    Text("No emulator cores are installed yet, so games cannot start.")
                    Spacer()
                    Button("Install Cores…") { model.openSettings(tab: .cores) }
                }
                .padding(10)
                .background(Color.orange.opacity(0.18))
            }
            if library.games.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                VStack { Spacer(); Text("No games here").foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
            } else if viewMode == "grid" {
                gridView
            } else {
                listView
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Drop game files or a folder here").font(.title2)
            Text("You must own the games you play. Files stay where they are; nothing is copied or uploaded.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Add Games…") { LibraryActions.chooseGames(library) }
                Button("Watch a Folder…") { LibraryActions.chooseFolder(library, watch: true) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsSingleSystem: Bool {
        if case .system = selection ?? .all { return true }
        return false
    }

    private var groupedGames: [(GameSystem, [Game])] {
        SystemCatalog.all.compactMap { system in
            let games = filtered.filter { $0.systemID == system.id }
            return games.isEmpty ? nil : (system, games)
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                if case .recent = selection ?? .all {
                    grid(filtered)
                } else {
                    ForEach(groupedGames, id: \.0.id) { system, games in
                        VStack(alignment: .leading, spacing: 8) {
                            if !showsSingleSystem {
                                Text(system.name).font(.headline)
                            }
                            grid(games)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func grid(_ games: [Game]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], spacing: 14) {
            ForEach(games) { game in
                GameCard(game: game, selected: selectedGame == game.id)
                    .onTapGesture(count: 2) { model.play(game) }
                    .onTapGesture { selectedGame = game.id }
                    .contextMenu { gameMenu(game) }
            }
        }
    }

    private var listView: some View {
        List(selection: $selectedGame) {
            ForEach(filtered) { game in
                HStack {
                    Image(systemName: game.system?.symbol ?? "questionmark")
                        .foregroundStyle(game.system?.color ?? .gray).frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(game.title)
                        Text(game.system?.name ?? "Unknown").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !library.fileExists(game) {
                        Label("File missing", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    if let played = game.lastPlayed {
                        Text(played, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { library.toggleFavorite(game) } label: {
                        Image(systemName: game.favorite ? "star.fill" : "star").foregroundStyle(game.favorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    Button("Play") { model.play(game) }
                }
                .tag(game.id)
                .contextMenu { gameMenu(game) }
            }
        }
    }

    @ViewBuilder
    private func gameMenu(_ game: Game) -> some View {
        Button("Play") { model.play(game) }
        Button(game.favorite ? "Remove from Favorites" : "Add to Favorites") { library.toggleFavorite(game) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
        Divider()
        Button("Remove from Library") { library.remove(game) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { library.add(urls: urls) }
        }
        return true
    }
}

/// A tile for the grid: generated from the title and system colour. No box art is bundled or fetched.
struct GameCard: View {
    let game: Game
    let selected: Bool
    @EnvironmentObject var library: GameLibrary
    @EnvironmentObject var cores: CoreCatalog

    var body: some View {
        let color = game.system?.color ?? .gray
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [color.opacity(0.9), color.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Image(systemName: game.system?.symbol ?? "questionmark").font(.system(size: 30))
                    Text(game.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if game.favorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).padding(6)
                }
            }
            .frame(height: 110)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.title).font(.caption).lineLimit(1)
                    Text(game.system?.shortName ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !library.fileExists(game) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("The file is missing")
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: selected ? 3 : 1))
        .shadow(radius: 2, y: 1)
    }
}
