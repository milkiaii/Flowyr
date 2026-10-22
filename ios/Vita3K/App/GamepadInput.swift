// Vita3K iOS shell app
// Physical gamepad input for the app's own UI (library navigation and the
// in-game menu). It only *polls* GCController state: it never installs value
// handlers, so it cannot interfere with the core's SDL gamepad input.

import Combine
import GameController

enum PadButton: Hashable {
    case up, down, left, right
    case confirm, back, x, y
    case start, select
    case l1, r1
    /// Start + Select held together (opens the in-game menu).
    case menuCombo
}

struct PadEvent: Equatable {
    let button: PadButton
    let seq: Int
}

@MainActor
final class GamepadInput: ObservableObject {
    static let shared = GamepadInput()

    @Published private(set) var connected = false
    @Published private(set) var lastEvent: PadEvent?

    private var owners = Set<AnyHashable>()
    private var timer: Timer?
    private var previous = Set<PadButton>()
    private var heldSince: [PadButton: Date] = [:]
    private var lastRepeat: [PadButton: Date] = [:]
    private var seq = 0

    private init() {}

    /// Polling runs while at least one owner (a screen) has started it.
    func start(owner: AnyHashable) {
        owners.insert(owner)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop(owner: AnyHashable) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        previous = []
        heldSince = [:]
        lastRepeat = [:]
    }

    private static let repeatable: Set<PadButton> = [.up, .down, .left, .right]

    private func poll() {
        let pads = GCController.controllers().compactMap { $0.extendedGamepad }
        let isConnected = !pads.isEmpty
        if isConnected != connected { connected = isConnected }

        var down = Set<PadButton>()
        for pad in pads {
            let sx = pad.leftThumbstick.xAxis.value
            let sy = pad.leftThumbstick.yAxis.value
            if pad.dpad.left.isPressed || sx < -0.6 { down.insert(.left) }
            if pad.dpad.right.isPressed || sx > 0.6 { down.insert(.right) }
            if pad.dpad.up.isPressed || sy > 0.6 { down.insert(.up) }
            if pad.dpad.down.isPressed || sy < -0.6 { down.insert(.down) }
            if pad.buttonA.isPressed { down.insert(.confirm) }
            if pad.buttonB.isPressed { down.insert(.back) }
            if pad.buttonX.isPressed { down.insert(.x) }
            if pad.buttonY.isPressed { down.insert(.y) }
            if pad.buttonMenu.isPressed { down.insert(.start) }
            if pad.buttonOptions?.isPressed == true { down.insert(.select) }
            if pad.leftShoulder.isPressed { down.insert(.l1) }
            if pad.rightShoulder.isPressed { down.insert(.r1) }
        }
        if down.contains(.start) && down.contains(.select) { down.insert(.menuCombo) }

        let now = Date()
        for button in down {
            if !previous.contains(button) {
                emit(button)
                heldSince[button] = now
                lastRepeat[button] = now
            } else if Self.repeatable.contains(button),
                      let since = heldSince[button], now.timeIntervalSince(since) > 0.4,
                      now.timeIntervalSince(lastRepeat[button] ?? now) > 0.12 {
                emit(button)
                lastRepeat[button] = now
            }
        }
        for button in previous.subtracting(down) {
            heldSince[button] = nil
            lastRepeat[button] = nil
        }
        previous = down
    }

    private func emit(_ button: PadButton) {
        seq += 1
        lastEvent = PadEvent(button: button, seq: seq)
    }
}
