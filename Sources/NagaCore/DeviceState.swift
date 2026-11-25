import Foundation

public protocol MouseIO: AnyObject {
    func execute(_ command: MouseCommand, allowWrites: Bool) throws -> [UInt8]
}

public struct HardwareBinding: Codable, Equatable, Sendable {
    public var control: UInt8
    public var function: [UInt8]
    public init(control: UInt8, function: [UInt8]) { self.control = control; self.function = function }
    public static func equivalent(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        func canonical(_ f: [UInt8]) -> [UInt8] {
            guard f.count == 7, f[0] == 2, f[1] == 1 else { return f }
            var f = f; f[1] = 2; f[2] = 0; return f
        }
        return canonical(a) == canonical(b)
    }
}

public struct DeviceState: Codable, Equatable, Sendable {
    public var serial: String
    public var bindings: [HardwareBinding]
    public var stageBytes: [UInt8]
    public var dpiX: Int
    public var dpiY: Int
    public var mode: UInt8
    public init(serial: String, bindings: [HardwareBinding], stageBytes: [UInt8], dpiX: Int, dpiY: Int, mode: UInt8) {
        self.serial = serial; self.bindings = bindings; self.stageBytes = stageBytes
        self.dpiX = dpiX; self.dpiY = dpiY; self.mode = mode
    }
    public var dpi: DPISettings { get throws { try DPIWire.decode(stageBytes) } }
    public func function(_ id: UInt8) throws -> [UInt8] {
        guard let f = bindings.first(where: { $0.control == id })?.function, f.count == 7 else {
            throw NagaError.protocolError("The button's current assignment could not be read.")
        }
        return f
    }
    public func validate() throws {
        guard !serial.isEmpty, serial != "UNKWN", !serial.hasPrefix("UNKWN"), serial.count <= 64,
              serial.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }),
              mode == 0, (100...30000).contains(dpiX), (100...30000).contains(dpiY),
              bindings.count == Self.controlIDs.count,
              Set(bindings.map(\.control)) == Set(Self.controlIDs), bindings.allSatisfy({ $0.function.count == 7 }) else {
            throw NagaError.unavailable("The mouse settings could not be read safely. Wake the mouse and try again. If another app changed the device mode, close that app first.")
        }
        _ = try dpi
    }
    public static let controlIDs = MouseControl.all.map(\.id) + [UInt8(0x0b), UInt8(0x0c)]
    public static func read(from io: MouseIO) throws -> Self {
        func get(_ c: MouseCommand) throws -> [UInt8] { try io.execute(c, allowWrites: false) }
        let serialBytes = try get(.serial)
        let serial = String(bytes: serialBytes.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
        let mode: [UInt8]
        do { mode = try get(.mode) }
        catch NagaError.status(4) { mode = try get(MouseCommand(group: 0, id: 0x84, payload: [0, 0], transaction: 0xff)) }
        guard mode[0] == 0, mode[1] == 0 else { throw NagaError.unavailable("The mouse is not in normal operating mode. Close the app that changed its mode and reconnect the receiver.") }
        let current = try get(.currentDPI)
        let stages = try get(.stages)
        let bindings = try controlIDs.map { id in
            HardwareBinding(control: id, function: Array(try get(.binding(id)).dropFirst(3)))
        }
        let state = Self(serial: serial, bindings: bindings, stageBytes: stages,
                         dpiX: Int(current[1]) << 8 | Int(current[2]), dpiY: Int(current[3]) << 8 | Int(current[4]), mode: mode[0])
        try state.validate()
        return state
    }
    public func makeProfile(label: (UInt16) -> String) throws -> MouseProfile {
        let assignments = try MouseControl.all.map { control -> Assignment in
            let f = try function(control.id)
            let action: ButtonAction
            if f.allSatisfy({ $0 == 0 }) { action = .disabled }
            else if let button = MouseButtonAction(hardwareFunction: f) { action = .mouseButton(button) }
            else if f[0] == 2, [1,2].contains(f[1]), f[2] & 0xf0 == 0, f[4...6].allSatisfy({ $0 == 0 }),
                    let code = HIDKeys.keyCode(for: f[3]) {
                action = .shortcut(Shortcut(keyCode: code, modifiers: KeyModifiers(rawValue: f[1] == 1 ? 0 : f[2]), keyLabel: label(code)))
            } else { action = .original }
            return Assignment(id: control.id, action: action)
        }
        return try MouseProfile(serial: serial, assignments: assignments, dpi: dpi)
    }
    public func sameConfiguration(as other: Self) -> Bool {
        guard serial == other.serial, mode == other.mode,
              let a = try? dpi, let b = try? other.dpi, a.stages == b.stages else { return false }
        return sameBindings(as: other)
    }

    func sameBindings(as other: Self) -> Bool {
        guard serial == other.serial, mode == other.mode else { return false }
        return Self.controlIDs.allSatisfy { id in
            guard let a = try? function(id), let b = try? other.function(id) else { return false }
            return HardwareBinding.equivalent(a, b)
        }
    }
}

public struct LocalRoute: Codable, Equatable, Sendable {
    public let control: UInt8
    public let usage: UInt8
    public let shortcut: Shortcut
    public init(control: UInt8, usage: UInt8, shortcut: Shortcut) { self.control = control; self.usage = usage; self.shortcut = shortcut }
}

public enum WriteOperation: Codable, Equatable, Sendable {
    case binding(UInt8, [UInt8])
    case stages([UInt8])
    case currentDPI(Int, Int)
    public var command: MouseCommand {
        switch self {
        case .binding(let id, let f): return MouseCommand(group: 2, id: 0x0c, payload: [1, id, 0] + f)
        case .stages(let bytes): return MouseCommand(group: 4, id: 6, payload: bytes)
        case .currentDPI(let x, let y): return MouseCommand(group: 4, id: 5, payload: [1, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255), 0, 0])
        }
    }
    public func undo(in state: DeviceState) throws -> Self {
        switch self {
        case .binding(let id, _): return try .binding(id, state.function(id))
        case .stages: return .stages(state.stageBytes)
        case .currentDPI: return .currentDPI(state.dpiX, state.dpiY)
        }
    }
    public func verify(using io: MouseIO) throws {
        switch self {
        case .binding(let id, let expected):
            for bank: UInt8 in [1, 0] {
                let actual = try io.execute(.binding(id, bank: bank), allowWrites: false)
                guard HardwareBinding.equivalent(Array(actual.dropFirst(3)), expected) else { throw NagaError.protocolError("The button assignment could not be verified by reading it back.") }
            }
        case .stages(let bytes):
            let actual = try io.execute(.stages, allowWrites: false)
            guard try DPIWire.decode(actual) == DPIWire.decode(bytes) else { throw NagaError.protocolError("The DPI stages could not be verified.") }
        case .currentDPI(let x, let y):
            let a = try io.execute(.currentDPI, allowWrites: false)
            guard Int(a[1]) << 8 | Int(a[2]) == x, Int(a[3]) << 8 | Int(a[4]) == y else { throw NagaError.protocolError("The active DPI could not be verified.") }
        }
    }
}

public struct ApplyPlan: Sendable {
    public let operations: [WriteOperation]
    public let routes: [LocalRoute]
    public let applicationTriggers: [ApplicationTrigger]
    public init(profile: MouseProfile, baseline: DeviceState, applicationProfiles: [ApplicationProfile] = []) throws {
        try profile.validate(); try baseline.validate()
        guard profile.serial == baseline.serial else { throw NagaError.invalid("This profile belongs to a different mouse.") }
        let applicationControls = try ApplicationProfile.controls(in: applicationProfiles)
        var desired: [UInt8: [UInt8]] = [:]
        var local: [Assignment] = []
        for assignment in profile.assignments.sorted(by: { $0.id < $1.id }) {
            if applicationControls.contains(assignment.id) {
                guard assignment.action != .original else {
                    let title = MouseControl.all.first { $0.id == assignment.id }?.title ?? "Button"
                    throw NagaError.invalid("First choose a default assignment for \(title) under Button Assignments.")
                }
                local.append(assignment)
                continue
            }
            switch assignment.action {
            case .original: desired[assignment.id] = try baseline.function(assignment.id)
            case .disabled: desired[assignment.id] = .init(repeating: 0, count: 7)
            case .mouseButton(let button): desired[assignment.id] = button.hardwareFunction
            case .shortcut(let shortcut):
                if let f = shortcut.hardwareFunction { desired[assignment.id] = f }
                else { local.append(assignment) }
            }
        }
        // Reserved trigger usages never overlap direct firmware keyboard outputs.
        // They are still matched to this physical mouse before suppression.
        var occupied = Set(desired.values.compactMap { f in f[0] == 2 ? f[3] : nil })
        for id: UInt8 in [0x0b, 0x0c] { let f = try baseline.function(id); if f[0] == 2 { occupied.insert(f[3]) } }
        var routes: [LocalRoute] = []
        var applicationTriggers: [ApplicationTrigger] = []
        for assignment in local {
            guard let marker = HIDKeys.markerCandidates.first(where: { !occupied.contains($0) }) else {
                throw NagaError.invalid("There are not enough independent triggers for assignments that run on the Mac.")
            }
            occupied.insert(marker)
            let trigger = ApplicationTrigger(control: assignment.id, usage: marker)
            desired[assignment.id] = trigger.hardwareFunction
            if applicationControls.contains(assignment.id) {
                applicationTriggers.append(trigger)
            } else if case .shortcut(let shortcut) = assignment.action {
                routes.append(LocalRoute(control: assignment.id, usage: marker, shortcut: shortcut))
            }
        }
        var ops: [WriteOperation] = []
        for id in desired.keys.sorted() {
            guard let f = desired[id] else { continue }
            if try !HardwareBinding.equivalent(f, baseline.function(id)) { ops.append(.binding(id, f)) }
        }
        let dpiChanged = try profile.dpi != baseline.dpi
        if dpiChanged {
            let stageBytes = try DPIWire.encode(profile.dpi, preserving: baseline.stageBytes)
            ops.append(.stages(stageBytes))
            let active = profile.dpi.stages[profile.dpi.active - 1]
            ops.append(.currentDPI(active.x, active.y))
        }
        if dpiChanged || applicationProfiles.contains(where: { $0.dpi != nil }) {
            for (id, direction): (UInt8, UInt8) in [(0x0b, 1), (0x0c, 2)] {
                let f: [UInt8] = [6, 1, direction, 0, 0, 0, 0]
                if try !HardwareBinding.equivalent(f, baseline.function(id)) { ops.append(.binding(id, f)) }
            }
        }
        self.operations = ops; self.routes = routes; self.applicationTriggers = applicationTriggers
    }
}
