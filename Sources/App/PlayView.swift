import SwiftUI

struct PlayView: View {
    @ObservedObject var session: PlaySession
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var input: InputMapper

    @State private var showControls = true
    @State private var hideWork: DispatchWorkItem?
    @State private var showStates = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            GameMetalView(box: session.engine.box)

            if let toast = session.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
                    .transition(.opacity)
            }
            if session.paused {
                Text("Paused").font(.largeTitle.bold()).foregroundStyle(.white)
                    .padding(20).background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            if showControls || session.paused || showStates {
                controlBar
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { wake() }
        }
        .onAppear { wake() }
        .onDisappear { hideWork?.cancel() }
        .navigationTitle(session.game.title)
    }

    private func wake() {
        showControls = true
        hideWork?.cancel()
        let work = DispatchWorkItem { withAnimation { showControls = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private var controllerLabel: String {
        if let first = input.controllers.first {
            return first.name + (input.controllers.count > 1 ? " +\(input.controllers.count - 1)" : "")
        }
        return "Keyboard"
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button { model.closeSession() } label: { Label("Library", systemImage: "chevron.left") }
                Divider().frame(height: 18)
                Button { session.paused.toggle() } label: {
                    Image(systemName: session.paused ? "play.fill" : "pause.fill")
                }
                .help(session.paused ? "Resume" : "Pause")
                Button { session.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset")
                Menu {
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 4.0], id: \.self) { value in
                        Button((value == 1 ? "Normal speed" : "\(value.formatted())×")) { session.speed = value }
                    }
                } label: {
                    Label(session.speed == 1 ? "1×" : "\(session.speed.formatted())×", systemImage: "speedometer")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Emulation speed (fast-forward is silent)")
                HStack(spacing: 4) {
                    Image(systemName: settings.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Slider(value: Binding(get: { Double(settings.volume) }, set: {
                        settings.volume = Float($0)
                        session.engine.audio.volume = Float($0)
                    }), in: 0...1)
                    .frame(width: 90)
                }
                Spacer()
                Label(controllerLabel, systemImage: input.controllers.isEmpty ? "keyboard" : "gamecontroller.fill")
                    .font(.caption)
                    .help(input.controllers.isEmpty ? "No controller connected: keyboard controls are active" : "Connected controller")
                Picker("Scale", selection: $settings.scaleMode) {
                    ForEach(ScaleMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 120)
                Picker("Filter", selection: $settings.filter) {
                    ForEach(VideoFilter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                Toggle("CRT", isOn: $settings.crtEffect).toggleStyle(.button)
                Button { showStates.toggle() } label: { Label("States", systemImage: "square.and.arrow.down") }
                    .popover(isPresented: $showStates, arrowEdge: .top) { statesPanel }
                Button { model.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Full screen")
            }
            Text("\(session.system.name) · \(session.core.name) · F5 quick save · F7 quick load · F8 pause")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private var statesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save States").font(.headline)
            HStack(spacing: 12) {
                ForEach(session.slots) { slot in
                    VStack(spacing: 6) {
                        ZStack {
                            Rectangle().fill(Color.black.opacity(0.25))
                            if let image = slot.thumbnail {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Text("Empty").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 130, height: 98)
                        .overlay(Rectangle().strokeBorder(session.currentSlot == slot.slot ? Color.accentColor : Color.clear, lineWidth: 2))
                        .onTapGesture { session.currentSlot = slot.slot }
                        Text("Slot \(slot.slot)").font(.caption.bold())
                        Text(slot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Save") { session.saveState(slot: slot.slot) }
                            Button("Load") { session.loadState(slot: slot.slot) }.disabled(slot.isEmpty)
                        }
                        .controlSize(.small)
                    }
                }
            }
            Text("Quick save/load use the highlighted slot (F5 / F7 or ⌘S / ⌘L). Battery saves are written automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
