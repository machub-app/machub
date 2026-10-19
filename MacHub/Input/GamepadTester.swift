import CoreHaptics
import Foundation
import GameController
import Observation

/// The controls a standard gamepad has. Names follow the Game Controller framework's extended gamepad.
enum GamepadControl: String, CaseIterable, Sendable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftThumbstickButton, rightThumbstickButton
    case buttonMenu, buttonOptions
    case leftStick, rightStick

    /// Controls every extended gamepad has; options, home and stick clicks are optional in the framework.
    static let required: [GamepadControl] = [
        .buttonA, .buttonB, .buttonX, .buttonY, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .buttonMenu, .leftStick, .rightStick,
    ]
}

/// One reading of the pad, decoupled from GCController so the checklist logic is testable.
struct GamepadReading: Equatable, Sendable {
    var pressed: Set<GamepadControl> = []
    var leftStick = CGPoint.zero
    var rightStick = CGPoint.zero
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
}

/// Which controls the user has exercised during the test. A stick counts once pushed past half way.
struct InputChecklist: Equatable, Sendable {
    private(set) var seen: Set<GamepadControl> = []
    let expected: [GamepadControl]

    init(expected: [GamepadControl] = GamepadControl.required) { self.expected = expected }

    mutating func record(_ reading: GamepadReading) {
        seen.formUnion(reading.pressed)
        if hypot(reading.leftStick.x, reading.leftStick.y) > 0.5 { seen.insert(.leftStick) }
        if hypot(reading.rightStick.x, reading.rightStick.y) > 0.5 { seen.insert(.rightStick) }
        if reading.leftTrigger > 0.5 { seen.insert(.leftTrigger) }
        if reading.rightTrigger > 0.5 { seen.insert(.rightTrigger) }
    }

    var completed: Int { expected.filter(seen.contains).count }
    var isComplete: Bool { completed == expected.count }
}

/// Reads one controller's live input while the test is on screen.
@MainActor @Observable
final class GamepadTester {
    private(set) var reading = GamepadReading()
    private(set) var checklist = InputChecklist()
    /// The framework's own label and SF Symbol per control (Cross/Circle on PlayStation, A/B on Xbox).
    private(set) var labels: [GamepadControl: (name: String, symbol: String)] = [:]
    private(set) var hapticsState: HapticsState = .idle
    private weak var controller: GCController?

    enum HapticsState: Equatable { case idle, playing, unavailable, failed }

    func attach(_ controller: GCController) {
        detach()
        self.controller = controller
        checklist = InputChecklist()
        reading = GamepadReading()
        guard let pad = controller.extendedGamepad else { return }
        labels = Self.labels(for: pad)
        pad.valueChangedHandler = { [weak self] pad, _ in
            let reading = Self.read(pad)
            MainActor.assumeIsolated {
                self?.reading = reading
                self?.checklist.record(reading)
            }
        }
    }

    func detach() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
    }

    func reset() { checklist = InputChecklist() }

    /// A short, gentle pulse. Only offered when the controller reports haptics.
    func pulse() {
        guard let haptics = controller?.haptics, let engine = haptics.createEngine(withLocality: .default) else {
            hapticsState = .unavailable
            return
        }
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
            ], relativeTime: 0, duration: 0.4)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            hapticsState = .playing
            try player.start(atTime: CHHapticTimeImmediate)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                engine.stop(completionHandler: nil)
                self?.hapticsState = .idle
            }
        } catch {
            hapticsState = .failed
        }
    }

    nonisolated static func read(_ pad: GCExtendedGamepad) -> GamepadReading {
        var r = GamepadReading()
        let buttons: [(GamepadControl, GCControllerButtonInput?)] = [
            (.buttonA, pad.buttonA), (.buttonB, pad.buttonB), (.buttonX, pad.buttonX), (.buttonY, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.dpadUp, pad.dpad.up), (.dpadDown, pad.dpad.down), (.dpadLeft, pad.dpad.left), (.dpadRight, pad.dpad.right),
            (.leftThumbstickButton, pad.leftThumbstickButton), (.rightThumbstickButton, pad.rightThumbstickButton),
            (.buttonMenu, pad.buttonMenu), (.buttonOptions, pad.buttonOptions),
        ]
        for (control, button) in buttons where button?.isPressed == true { r.pressed.insert(control) }
        r.leftTrigger = pad.leftTrigger.value
        r.rightTrigger = pad.rightTrigger.value
        if pad.leftTrigger.isPressed { r.pressed.insert(.leftTrigger) }
        if pad.rightTrigger.isPressed { r.pressed.insert(.rightTrigger) }
        r.leftStick = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
        r.rightStick = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))
        return r
    }

    private static func labels(for pad: GCExtendedGamepad) -> [GamepadControl: (name: String, symbol: String)] {
        let elements: [(GamepadControl, GCControllerElement?)] = [
            (.buttonA, pad.buttonA), (.buttonB, pad.buttonB), (.buttonX, pad.buttonX), (.buttonY, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.leftTrigger, pad.leftTrigger), (.rightTrigger, pad.rightTrigger),
            (.dpadUp, pad.dpad.up), (.dpadDown, pad.dpad.down), (.dpadLeft, pad.dpad.left), (.dpadRight, pad.dpad.right),
            (.leftThumbstickButton, pad.leftThumbstickButton), (.rightThumbstickButton, pad.rightThumbstickButton),
            (.buttonMenu, pad.buttonMenu), (.buttonOptions, pad.buttonOptions),
            (.leftStick, pad.leftThumbstick), (.rightStick, pad.rightThumbstick),
        ]
        var result: [GamepadControl: (String, String)] = [:]
        for (control, element) in elements {
            guard let element else { continue }
            result[control] = (element.localizedName ?? control.rawValue, element.sfSymbolsName ?? "circle")
        }
        return result
    }
}
