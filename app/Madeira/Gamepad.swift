import Foundation
import GameController
import CoreHaptics

// In-game controllers: GameController.framework -> XInput.
//
// Wine runs inside this process, so instead of a driver stack the XInput DLLs
// (build/xinput-madeira/xinput.c) read a small block of memory this class owns.
// Its address is published as MADEIRA_PAD_SHM before Wine starts. Rumble flows
// back through the same block and is played on the controller's haptics.
//
// Layout (little-endian, must match xinput.c):
//   header  magic "MPAD" u32 | version u32 | slot_count u32 | slot_size u32
//   slot[i] at 16 + 32*i:
//     0 connected u32   4 packet u32   8 buttons u16   10 lt u8   11 rt u8
//     12 lx i16  14 ly i16  16 rx i16  18 ry i16
//     20 rumbleL u16  22 rumbleR u16  24 rumbleSeq u32 (game-written)
//     28 batteryType u8  29 batteryLevel u8  30 reserved u16
final class GamepadBridge {
    static let shared = GamepadBridge()

    static let slotCount = 4
    static let slotSize = 32
    private static let headerSize = 16

    private let block: UnsafeMutableRawPointer
    private var pads: [GCController?] = Array(repeating: nil, count: GamepadBridge.slotCount)
    private var rumblers: [PadRumble?] = Array(repeating: nil, count: GamepadBridge.slotCount)
    private var lastRumble: [UInt32] = Array(repeating: 0, count: GamepadBridge.slotCount)
    private var packets: [UInt32] = Array(repeating: 0, count: GamepadBridge.slotCount)
    private var rumbleTimer: Timer?
    private let queue = DispatchQueue(label: "madeira.gamepad", qos: .userInteractive)
    private var started = false

    /// On-screen Xbox buttons (touch controls) merge into slot 0.
    private var virtualButtons: UInt16 = 0
    private var virtualLT: UInt8 = 0
    private var virtualRT: UInt8 = 0
    var virtualPadEnabled = false { didSet { queue.async { self.publish(slot: 0) } } }

    private init() {
        let size = Self.headerSize + Self.slotSize * Self.slotCount
        block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        block.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        block.storeBytes(of: UInt32(0x4441_504D), toByteOffset: 0, as: UInt32.self)   // "MPAD"
        block.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self)
        block.storeBytes(of: UInt32(Self.slotCount), toByteOffset: 8, as: UInt32.self)
        block.storeBytes(of: UInt32(Self.slotSize), toByteOffset: 12, as: UInt32.self)
    }

    /// Value for MADEIRA_PAD_SHM.
    var environmentValue: String { String(UInt(bitPattern: block), radix: 16) }

    func start() {
        guard !started else { return }
        started = true
        setenv("MADEIRA_PAD_SHM", environmentValue, 1)
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.connect(c) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.disconnect(c) }
        }
        for c in GCController.controllers() { connect(c) }
        rumbleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pumpRumble()
        }
    }

    // MARK: connection

    private func connect(_ c: GCController) {
        guard c.extendedGamepad != nil, !pads.contains(where: { $0 === c }) else { return }
        guard let i = pads.firstIndex(where: { $0 == nil }) else { return }
        pads[i] = c
        c.playerIndex = GCControllerPlayerIndex(rawValue: i) ?? .indexUnset
        c.handlerQueue = queue
        c.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            self?.publish(slot: i)
        }
        rumblers[i] = PadRumble(controller: c)
        queue.async { self.publish(slot: i) }
    }

    private func disconnect(_ c: GCController) {
        guard let i = pads.firstIndex(where: { $0 === c }) else { return }
        pads[i] = nil
        rumblers[i]?.stop()
        rumblers[i] = nil
        queue.async { self.publish(slot: i) }
    }

    // MARK: state

    private func off(_ slot: Int, _ field: Int) -> Int { Self.headerSize + Self.slotSize * slot + field }

    private func axis(_ v: Float) -> Int16 { Int16(max(-32768, min(32767, (v * 32767).rounded()))) }
    private func trigger(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

    /// Runs on `queue` (the controllers' handler queue).
    private func publish(slot i: Int) {
        var buttons: UInt16 = 0
        var lt: UInt8 = 0, rt: UInt8 = 0
        var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
        var battery: (UInt8, UInt8) = (0, 0)
        var connected = false

        if let pad = pads[i]?.extendedGamepad {
            connected = true
            func b(_ e: GCControllerButtonInput?, _ mask: UInt16) { if e?.isPressed == true { buttons |= mask } }
            b(pad.dpad.up, 0x0001); b(pad.dpad.down, 0x0002); b(pad.dpad.left, 0x0004); b(pad.dpad.right, 0x0008)
            b(pad.buttonMenu, 0x0010); b(pad.buttonOptions, 0x0020)
            b(pad.leftThumbstickButton, 0x0040); b(pad.rightThumbstickButton, 0x0080)
            b(pad.leftShoulder, 0x0100); b(pad.rightShoulder, 0x0200)
            b(pad.buttonHome, 0x0400)
            b(pad.buttonA, 0x1000); b(pad.buttonB, 0x2000); b(pad.buttonX, 0x4000); b(pad.buttonY, 0x8000)
            lt = trigger(pad.leftTrigger.value)
            rt = trigger(pad.rightTrigger.value)
            lx = axis(pad.leftThumbstick.xAxis.value); ly = axis(pad.leftThumbstick.yAxis.value)
            rx = axis(pad.rightThumbstick.xAxis.value); ry = axis(pad.rightThumbstick.yAxis.value)
            if let bat = pads[i]?.battery {
                // BATTERY_TYPE_ALKALINE-style reporting: 0 empty .. 3 full.
                let level = UInt8(min(3, max(0, Int(bat.batteryLevel * 4))))
                battery = bat.batteryState == .charging || bat.batteryState == .full ? (1, 3) : (3, level)
            }
        }
        if i == 0 && virtualPadEnabled {
            connected = true
            buttons |= virtualButtons
            lt = max(lt, virtualLT)
            rt = max(rt, virtualRT)
        }

        packets[i] &+= 1
        block.storeBytes(of: buttons, toByteOffset: off(i, 8), as: UInt16.self)
        block.storeBytes(of: lt, toByteOffset: off(i, 10), as: UInt8.self)
        block.storeBytes(of: rt, toByteOffset: off(i, 11), as: UInt8.self)
        block.storeBytes(of: lx, toByteOffset: off(i, 12), as: Int16.self)
        block.storeBytes(of: ly, toByteOffset: off(i, 14), as: Int16.self)
        block.storeBytes(of: rx, toByteOffset: off(i, 16), as: Int16.self)
        block.storeBytes(of: ry, toByteOffset: off(i, 18), as: Int16.self)
        block.storeBytes(of: battery.0, toByteOffset: off(i, 28), as: UInt8.self)
        block.storeBytes(of: battery.1, toByteOffset: off(i, 29), as: UInt8.self)
        // Packet last: XInput games treat an unchanged packet number as "no new input".
        block.storeBytes(of: packets[i], toByteOffset: off(i, 4), as: UInt32.self)
        block.storeBytes(of: UInt32(connected ? 1 : 0), toByteOffset: off(i, 0), as: UInt32.self)
    }

    // MARK: on-screen pad

    /// Xbox button names used by the touch-control mapping panel.
    func setVirtual(_ name: String, down: Bool) {
        queue.async {
            let mask: UInt16
            switch name {
            case "A": mask = 0x1000
            case "B": mask = 0x2000
            case "X": mask = 0x4000
            case "Y": mask = 0x8000
            case "D↑": mask = 0x0001
            case "D↓": mask = 0x0002
            case "D←": mask = 0x0004
            case "D→": mask = 0x0008
            case "Menu": mask = 0x0010
            case "View": mask = 0x0020
            case "L3", "LS": mask = 0x0040
            case "R3", "RS": mask = 0x0080
            case "LB": mask = 0x0100
            case "RB": mask = 0x0200
            case "Guide": mask = 0x0400
            case "LT": self.virtualLT = down ? 255 : 0; mask = 0
            case "RT": self.virtualRT = down ? 255 : 0; mask = 0
            default: return
            }
            if down { self.virtualButtons |= mask } else { self.virtualButtons &= ~mask }
            self.publish(slot: 0)
        }
    }

    // MARK: rumble

    private func pumpRumble() {
        for i in 0..<Self.slotCount {
            guard let r = rumblers[i] else { continue }
            let seq = block.load(fromByteOffset: off(i, 24), as: UInt32.self)
            guard seq != lastRumble[i] else { continue }
            lastRumble[i] = seq
            let l = block.load(fromByteOffset: off(i, 20), as: UInt16.self)
            let h = block.load(fromByteOffset: off(i, 22), as: UInt16.self)
            // Low-frequency (left) motor reads as strength, high-frequency (right) as sharpness.
            r.set(strength: Float(max(l, h)) / 65535, sharpness: Float(h) / 65535)
        }
    }
}

/// Continuous controller haptics driven by XInput motor speeds.
final class PadRumble {
    private let engine: CHHapticEngine
    private var player: CHHapticAdvancedPatternPlayer?

    init?(controller: GCController) {
        guard let e = controller.haptics?.createEngine(withLocality: .default) else { return nil }
        engine = e
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak self] in self?.player = nil; try? self?.engine.start() }
        try? engine.start()
    }

    func set(strength: Float, sharpness: Float) {
        guard strength > 0.02 else { stop(); return }
        if player == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
            ], relativeTime: 0, duration: 30)
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
                  let p = try? engine.makeAdvancedPlayer(with: pattern) else { return }
            p.loopEnabled = true
            try? engine.start()
            try? p.start(atTime: CHHapticTimeImmediate)
            player = p
        }
        try? player?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.4, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }
}
