import Foundation

public struct MouseControl: Codable, Hashable, Identifiable, Sendable {
    public let id: UInt8
    public let number: Int?
    public var title: String { number.map { "Side button \($0)" } ?? (id == 0x34 ? "Wheel · left" : "Wheel · right") }
    public static let all: [Self] = (1...12).map { Self(id: UInt8(0x3f + $0), number: $0) }
        + [Self(id: 0x34, number: nil), Self(id: 0x35, number: nil)]
    public static let editableIDs = Set(all.map(\.id))
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    public static let fn = Self(rawValue: 16)
    public var symbols: String {
        (contains(.fn) ? "fn " : "") + (contains(.control) ? "⌃" : "")
        + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var keyLabel: String
    public init(keyCode: UInt16, modifiers: KeyModifiers = [], keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    public var label: String { modifiers.symbols + keyLabel }
    public var hardwareFunction: [UInt8]? {
        guard modifiers.rawValue & 0xf0 == 0, let usage = HIDKeys.usage(for: keyCode) else { return nil }
        return [2, 2, modifiers.rawValue, usage, 0, 0, 0]
    }
}

public enum MouseButtonAction: UInt8, Codable, CaseIterable, Sendable {
    case button4 = 4
    case button5 = 5

    public var label: String { "Mouse\(rawValue)" }
    public var title: String { "\(label) · Mouse button \(rawValue)" }
    // Razer function 1 takes a button ordinal, not a USB report bitmask.
    public var hardwareFunction: [UInt8] { [1, 1, rawValue, 0, 0, 0, 0] }
    public init?(hardwareFunction: [UInt8]) {
        guard let value = Self.allCases.first(where: { $0.hardwareFunction == hardwareFunction }) else { return nil }
        self = value
    }
}

public enum ButtonAction: Codable, Equatable, Sendable {
    case original
    case disabled
    case shortcut(Shortcut)
    case mouseButton(MouseButtonAction)
    public var label: String {
        switch self {
        case .original: return "Unrecognized Assignment"
        case .disabled: return "Disabled"
        case .shortcut(let s): return s.label
        case .mouseButton(let button): return button.label
        }
    }
    public var needsMac: Bool {
        if case .shortcut(let shortcut) = self { return shortcut.hardwareFunction == nil }
        return false
    }

    var hardwareFunction: [UInt8]? {
        switch self {
        case .original: return nil
        case .disabled: return .init(repeating: 0, count: 7)
        case .shortcut(let shortcut): return shortcut.hardwareFunction
        case .mouseButton(let button): return button.hardwareFunction
        }
    }

    func validate() throws {
        if case .shortcut(let shortcut) = self {
            guard shortcut.keyCode < 128, !shortcut.keyLabel.isEmpty, shortcut.modifiers.rawValue & 0xe0 == 0 else {
                throw NagaError.invalid("Invalid keyboard shortcut.")
            }
        }
    }
}

public struct Assignment: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt8
    public var action: ButtonAction
    public init(id: UInt8, action: ButtonAction) { self.id = id; self.action = action }
}

public struct DPIStage: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int? = nil) { self.x = x; self.y = y ?? x }
}

public struct DPISettings: Codable, Equatable, Sendable {
    public var stages: [DPIStage]
    /// The receiver uses a one-based active stage.
    public var active: Int
    public init(stages: [DPIStage], active: Int) { self.stages = stages; self.active = active }
    public func validate() throws {
        guard (1...5).contains(stages.count), (1...stages.count).contains(active),
              stages.allSatisfy({ (100...30000).contains($0.x) && (100...30000).contains($0.y) }) else {
            throw NagaError.invalid("Choose 1–5 stages. Each DPI value must be between 100 and 30000.")
        }
    }
}

public struct MouseProfile: Codable, Equatable, Sendable {
    public var version = 1
    public var serial: String
    public var assignments: [Assignment]
    public var dpi: DPISettings
    public init(serial: String, assignments: [Assignment], dpi: DPISettings) {
        self.serial = serial; self.assignments = assignments; self.dpi = dpi
    }
    public func validate() throws {
        try dpi.validate()
        guard version == 1, !serial.isEmpty, assignments.count == MouseControl.all.count,
              Set(assignments.map(\.id)) == MouseControl.editableIDs else { throw NagaError.invalid("The profile is incomplete or invalid.") }
        for assignment in assignments { try assignment.action.validate() }
    }
}

/// USB HID usages and macOS physical key positions. Layout labels are captured separately.
public enum HIDKeys {
    private static let pairs: [(UInt8, UInt16)] = {
        var p: [(UInt8, UInt16)] = []
        let groups: [(UInt8, [UInt16])] = [
            (0x04, [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]),
            (0x1e, [18,19,20,21,23,22,26,28,25,29]),
            (0x28, [36,53,51,48,49,27,24,33,30,42]),
            (0x33, [41,39,50,43,47,44,57]),
            (0x3a, [122,120,99,118,96,97,98,100,101,109,103,111]),
            (0x49, [114,115,116,117,119,121,124,123,125,126]),
            (0x54, [75,67,78,69,76,83,84,85,86,87,88,89,91,92,82,65]),
            (0x68, [105,107,113,106,64,79,80,90])
        ]
        for (base, codes) in groups { for (i, code) in codes.enumerated() { p.append((base + UInt8(i), code)) } }
        p += [(0x64, 10), (0x67, 81)]
        return p
    }()
    public static func usage(for code: UInt16) -> UInt8? { pairs.first { $0.1 == code }?.0 }
    public static func keyCode(for usage: UInt8) -> UInt16? { pairs.first { $0.0 == usage }?.1 }
    // Prefer F16–F20, then F13. F14/F15 are excluded because macOS gives them
    // brightness functions even while our app is closed.
    public static let markerCandidates: [UInt8] = Array(0x6b...0x6f) + [0x68] + Array((0x3a...0x45).reversed())
}
