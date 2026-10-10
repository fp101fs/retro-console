import AppKit
import Combine
import Foundation
import GameController

/// Pressed RetroPad buttons, shared between the main thread (input sources) and the
/// emulation thread (the core's input poll). Pad and keyboard are kept apart and OR-ed.
final class InputState {
    private let lock = NSLock()
    private var pad: UInt32 = 0
    private var keys: UInt32 = 0

    var bits: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return pad | keys
    }

    func setPad(_ value: UInt32) { lock.lock(); pad = value; lock.unlock() }
    func setKeys(_ value: UInt32) { lock.lock(); keys = value; lock.unlock() }
    func clear() { lock.lock(); pad = 0; keys = 0; lock.unlock() }
}

/// Physical pad controls, named by position so every common pad (Xbox, DualSense, 8BitDo,
/// MFi) behaves the same through the GameController framework.
enum PadControl: String, CaseIterable, Codable {
    case south, east, west, north
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftStickButton, rightStickButton
    case menu, options
    case stickUp, stickDown, stickLeft, stickRight

    var label: String {
        switch self {
        case .south: return "Bottom button (A/✕)"
        case .east: return "Right button (B/○)"
        case .west: return "Left button (X/□)"
        case .north: return "Top button (Y/△)"
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .leftShoulder: return "Left bumper"
        case .rightShoulder: return "Right bumper"
        case .leftTrigger: return "Left trigger"
        case .rightTrigger: return "Right trigger"
        case .leftStickButton: return "Left stick click"
        case .rightStickButton: return "Right stick click"
        case .menu: return "Menu / Start"
        case .options: return "Options / Back"
        case .stickUp: return "Left stick up"
        case .stickDown: return "Left stick down"
        case .stickLeft: return "Left stick left"
        case .stickRight: return "Left stick right"
        }
    }
}

struct ButtonMapping: Codable, Equatable {
    var pad: [String: RetroButton]
    var keyboard: [String: RetroButton]   // key = NSEvent.keyCode

    /// Nintendo-style layout (bottom button = B), D-pad and left stick = directions.
    /// Keyboard: arrows, Z/X/A/S, Q/W shoulders, Return = Start, Tab = Select.
    static let `default` = ButtonMapping(
        pad: [
            "south": .b, "east": .a, "west": .y, "north": .x,
            "dpadUp": .up, "dpadDown": .down, "dpadLeft": .left, "dpadRight": .right,
            "stickUp": .up, "stickDown": .down, "stickLeft": .left, "stickRight": .right,
            "leftShoulder": .l, "rightShoulder": .r, "leftTrigger": .l2, "rightTrigger": .r2,
            "leftStickButton": .l3, "rightStickButton": .r3, "menu": .start, "options": .select,
        ],
        keyboard: [
            "126": .up, "125": .down, "123": .left, "124": .right,
            "6": .b, "7": .a, "0": .y, "1": .x, "12": .l, "13": .r,
            "36": .start, "48": .select, "14": .l2, "15": .r2,
        ])

    static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            126: "↑", 125: "↓", 123: "←", 124: "→", 36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
            37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 53: "Esc",
        ]
        return names[code] ?? "Key \(code)"
    }
}

struct ControllerInfo: Identifiable, Equatable {
    let id: ObjectIdentifier
    let name: String
    let kind: String
}

enum InputCapture {
    case pad(PadControl)
    case key(Int)
}

enum Hotkey { case quickSave, quickLoad, pause }

final class InputMapper: ObservableObject {
    static let shared = InputMapper()

    let state = InputState()
    @Published private(set) var controllers: [ControllerInfo] = []
    @Published private(set) var mappings: [String: ButtonMapping] = [:]

    /// Set while a system is being played; routes input through that system's mapping.
    var activeSystemID: String?
    /// Set by the mapping screen while it waits for the next press.
    var captureHandler: ((InputCapture) -> Void)?
    var onHotkey: ((Hotkey) -> Void)?

    private var pressedKeys = Set<Int>()
    private var lastPadControls = Set<PadControl>()
    private var monitor: Any?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("mapping.") {
            let id = String(key.dropFirst("mapping.".count))
            if let data = UserDefaults.standard.data(forKey: key), let mapping = try? JSONDecoder().decode(ButtonMapping.self, from: data) {
                mappings[id] = mapping
            }
        }
        for name in [Notification.Name.GCControllerDidConnect, Notification.Name.GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.controllersChanged()
            }
        }
        controllersChanged()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    func mapping(for systemID: String) -> ButtonMapping { mappings[systemID] ?? .default }

    func setMapping(_ mapping: ButtonMapping, for systemID: String) {
        mappings[systemID] = mapping
        if let data = try? JSONEncoder().encode(mapping) { UserDefaults.standard.set(data, forKey: "mapping.\(systemID)") }
    }

    func resetMapping(for systemID: String) {
        mappings[systemID] = nil
        UserDefaults.standard.removeObject(forKey: "mapping.\(systemID)")
    }

    func releaseAll() {
        pressedKeys.removeAll()
        lastPadControls.removeAll()
        state.clear()
    }

    // MARK: Controllers

    private func controllersChanged() {
        let list = GCController.controllers()
        controllers = list.map {
            ControllerInfo(id: ObjectIdentifier($0), name: $0.vendorName ?? "Game Controller", kind: $0.productCategory)
        }
        for controller in list {
            guard let gamepad = controller.extendedGamepad else { continue }
            gamepad.valueChangedHandler = { [weak self] gamepad, _ in
                self?.padChanged(gamepad)
            }
        }
        if list.isEmpty { state.setPad(0) }
    }

    private func padChanged(_ gamepad: GCExtendedGamepad) {
        // Player 1 is the first connected controller; others are ignored.
        guard let first = GCController.controllers().first, gamepad.controller === first else { return }
        var down = Set<PadControl>()
        func check(_ control: PadControl, _ input: GCControllerButtonInput?) {
            if input?.isPressed == true { down.insert(control) }
        }
        check(.south, gamepad.buttonA); check(.east, gamepad.buttonB)
        check(.west, gamepad.buttonX); check(.north, gamepad.buttonY)
        check(.dpadUp, gamepad.dpad.up); check(.dpadDown, gamepad.dpad.down)
        check(.dpadLeft, gamepad.dpad.left); check(.dpadRight, gamepad.dpad.right)
        check(.leftShoulder, gamepad.leftShoulder); check(.rightShoulder, gamepad.rightShoulder)
        check(.leftTrigger, gamepad.leftTrigger); check(.rightTrigger, gamepad.rightTrigger)
        check(.leftStickButton, gamepad.leftThumbstickButton); check(.rightStickButton, gamepad.rightThumbstickButton)
        check(.menu, gamepad.buttonMenu); check(.options, gamepad.buttonOptions)
        check(.stickUp, gamepad.leftThumbstick.up); check(.stickDown, gamepad.leftThumbstick.down)
        check(.stickLeft, gamepad.leftThumbstick.left); check(.stickRight, gamepad.leftThumbstick.right)

        if let capture = captureHandler {
            if let new = down.subtracting(lastPadControls).first { capture(.pad(new)) }
            lastPadControls = down
            return
        }
        lastPadControls = down
        guard let systemID = activeSystemID else { return }
        let mapping = self.mapping(for: systemID)
        var bits: UInt32 = 0
        for control in down {
            if let button = mapping.pad[control.rawValue] { bits |= 1 << button.bit }
        }
        state.setPad(bits)
    }

    // MARK: Keyboard (fallback)

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let code = Int(event.keyCode)
        if let capture = captureHandler {
            if event.type == .keyDown && !event.isARepeat { capture(.key(code)) }
            return nil
        }
        guard let systemID = activeSystemID, !event.modifierFlags.contains(.command) else { return event }
        let isDown = event.type == .keyDown
        if isDown && !event.isARepeat {
            switch code {
            case 96: onHotkey?(.quickSave); return nil   // F5
            case 98: onHotkey?(.quickLoad); return nil   // F7
            case 100: onHotkey?(.pause); return nil      // F8
            default: break
            }
        }
        let mapping = self.mapping(for: systemID)
        guard mapping.keyboard[String(code)] != nil else { return event }
        if isDown { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        var bits: UInt32 = 0
        for key in pressedKeys {
            if let button = mapping.keyboard[String(key)] { bits |= 1 << button.bit }
        }
        state.setKeys(bits)
        return nil
    }
}
