import Foundation

public enum NagaError: LocalizedError {
    case invalid(String), protocolError(String), unavailable(String), io(String), storage(String), status(UInt8)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .protocolError(let s), .unavailable(let s), .io(let s), .storage(let s): return s
        case .status(let status):
            switch status {
            case 1: return "The mouse is busy. Try again."
            case 3: return "The mouse rejected the command."
            case 4: return "The mouse did not respond. Wake it and try again."
            case 5: return "The mouse does not support this command."
            default: return "Unexpected device response (\(status))."
            }
        }
    }
}

/// Wire formats: OpenRazer razercommon / razerchromacommon and issue 2845.
/// This allowlist intentionally contains no firmware, reset or device-mode writes.
public struct MouseCommand: Sendable {
    public let group: UInt8
    public let id: UInt8
    public let payload: [UInt8]
    public let transaction: UInt8
    public var isRead: Bool { id & 0x80 != 0 }
    public init(group: UInt8, id: UInt8, payload: [UInt8], transaction: UInt8 = 0x1f) {
        self.group = group; self.id = id; self.payload = payload; self.transaction = transaction
    }
    public func validate(allowWrites: Bool) throws {
        let size = payload.count
        let readAllowed = isRead && ["0:130:22", "0:132:2", "4:133:7", "4:134:38", "2:140:10"].contains("\(group):\(id):\(size)")
        let writeAllowed = allowWrites && !isRead && (
            (group == 2 && id == 12 && size == 10 && payload[0] == 1 && payload[2] == 0
             && (MouseControl.editableIDs.union([0x0b, 0x0c])).contains(payload[1]))
            || (group == 4 && id == 6 && size == 38 && payload[0] == 1)
            || (group == 4 && id == 5 && size == 7 && payload[0] == 1))
        guard readAllowed || writeAllowed else { throw NagaError.invalid("A disallowed hardware command was blocked.") }
        if group == 4 && id == 6 { _ = try DPIWire.decode(payload) }
        if group == 4 && id == 5 {
            guard (100...30000).contains(Int(payload[1]) << 8 | Int(payload[2])),
                  (100...30000).contains(Int(payload[3]) << 8 | Int(payload[4])) else { throw NagaError.invalid("Invalid DPI command.") }
        }
        if group == 2 && id == 140 {
            guard payload[0] <= 1, payload[2] == 0,
                  MouseControl.editableIDs.union([0x0b, 0x0c]).contains(payload[1]) else { throw NagaError.invalid("Invalid button read command.") }
        }
    }
    public func packet() -> [UInt8] {
        precondition(payload.count <= 80)
        var b = [UInt8](repeating: 0, count: 90)
        b[1] = transaction; b[5] = UInt8(payload.count); b[6] = group; b[7] = id
        b.replaceSubrange(8..<(8 + payload.count), with: payload)
        b[88] = Self.checksum(b)
        return b
    }
    public static func checksum(_ b: [UInt8]) -> UInt8 { b[2..<88].reduce(0, ^) }
    public func response(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count == 90, b[88] == Self.checksum(b), b[2...4].allSatisfy({ $0 == 0 }), b[89] == 0,
              b[1] == transaction, b[6] == group, b[7] == id else { throw NagaError.protocolError("The device response has an invalid identity or checksum.") }
        guard b[0] == 2 else { throw NagaError.status(b[0]) }
        guard Int(b[5]) == payload.count else { throw NagaError.protocolError("The device response is incomplete.") }
        let answer = Array(b[8..<(8 + payload.count)])
        if group == 2 && id == 0x8c {
            guard answer[0] == payload[0], answer[1] == payload[1] else { throw NagaError.protocolError("A response for a different button was received.") }
        }
        return answer
    }
    public func shouldPoll(_ b: [UInt8]) -> Bool {
        guard b.count == 90, b[88] == Self.checksum(b), b[5] <= 80 else { return false }
        if b[0] == 1 { return true }
        if b[1] != transaction || b[6] != group || b[7] != id { return true }
        return b[0] == 2 && group == 2 && id == 0x8c && (b[8] != payload[0] || b[9] != payload[1])
    }
    public static let serial = Self(group: 0, id: 0x82, payload: .init(repeating: 0, count: 22))
    public static let mode = Self(group: 0, id: 0x84, payload: [0, 0])
    public static let currentDPI = Self(group: 4, id: 0x85, payload: .init(repeating: 0, count: 7))
    public static let stages = Self(group: 4, id: 0x86, payload: [1] + .init(repeating: 0, count: 37))
    public static func binding(_ control: UInt8, bank: UInt8 = 1) -> Self {
        Self(group: 2, id: 0x8c, payload: [bank, control, 0, 0, 0, 0, 0, 0, 0, 0])
    }
}

public enum DPIWire {
    public static func decode(_ bytes: [UInt8]) throws -> DPISettings {
        guard bytes.count == 38, bytes[0] == 1, (1...5).contains(bytes[2]) else { throw NagaError.protocolError("The DPI stages are invalid.") }
        let count = Int(bytes[2])
        let stages = (0..<count).map { i -> DPIStage in
            let offset = 4 + i * 7
            return DPIStage(x: Int(bytes[offset]) << 8 | Int(bytes[offset + 1]), y: Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        let settings = DPISettings(stages: stages, active: Int(bytes[1]))
        try settings.validate()
        return settings
    }
    public static func encode(_ settings: DPISettings, preserving original: [UInt8]) throws -> [UInt8] {
        try settings.validate()
        guard original.count == 38 else { throw NagaError.invalid("The DPI backup is incomplete.") }
        var bytes = original
        bytes[0] = 1; bytes[1] = UInt8(settings.active); bytes[2] = UInt8(settings.stages.count)
        for (i, stage) in settings.stages.enumerated() {
            let offset = 3 + i * 7
            bytes[offset] = UInt8(i)
            bytes[offset + 1] = UInt8(stage.x >> 8); bytes[offset + 2] = UInt8(stage.x & 255)
            bytes[offset + 3] = UInt8(stage.y >> 8); bytes[offset + 4] = UInt8(stage.y & 255)
        }
        return bytes
    }
}
