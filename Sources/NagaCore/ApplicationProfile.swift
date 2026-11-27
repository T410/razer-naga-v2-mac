import Foundation

public struct ApplicationProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Target: Codable, Hashable, Sendable {
        case bundleIdentifier(String)
        case wineExecutable(String)
        case unlinkedWineExecutable

        private enum StoredTarget: Codable {
            case bundleIdentifier(String)
            case wineExecutable(String)
            case unlinkedWineExecutable
            case skyrimWine
        }

        public init(from decoder: Decoder) throws {
            switch try StoredTarget(from: decoder) {
            case .bundleIdentifier(let identifier): self = .bundleIdentifier(identifier)
            case .wineExecutable(let filename): self = .wineExecutable(filename.lowercased())
            case .unlinkedWineExecutable, .skyrimWine: self = .unlinkedWineExecutable
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .bundleIdentifier(let identifier): try StoredTarget.bundleIdentifier(identifier).encode(to: encoder)
            case .wineExecutable(let filename): try StoredTarget.wineExecutable(filename).encode(to: encoder)
            case .unlinkedWineExecutable: try StoredTarget.unlinkedWineExecutable.encode(to: encoder)
            }
        }
    }

    public let id: Target
    public let name: String
    public var assignments: [Assignment] = []
    public var dpi: DPISettings?

    public init(target: Target, name: String) {
        id = target
        self.name = name
    }

    static func controls(in profiles: [Self]) throws -> Set<UInt8> {
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw NagaError.invalid("An application cannot have more than one profile.")
        }
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(profile.assignments.map(\.id)).count == profile.assignments.count,
                  profile.assignments.allSatisfy({ MouseControl.editableIDs.contains($0.id) && $0.action != .original }) else {
                throw NagaError.invalid("The application profile is invalid.")
            }
            if case .bundleIdentifier(let identifier) = profile.id, identifier.isEmpty {
                throw NagaError.invalid("The application identifier is missing.")
            }
            if case .wineExecutable(let filename) = profile.id {
                guard filename.hasSuffix(".exe"), filename.count > 4,
                      filename == filename.lowercased(), !filename.contains("/"), !filename.contains("\\") else {
                    throw NagaError.invalid("The Wine application's filename is invalid.")
                }
            }
            for assignment in profile.assignments { try assignment.action.validate() }
            try profile.dpi?.validate()
        }
        return Set(profiles.flatMap { $0.assignments.map(\.id) })
    }
}

public struct ApplicationTrigger: Codable, Equatable, Sendable {
    public let control: UInt8
    public let usage: UInt8

    var hardwareFunction: [UInt8] { [2, 2, 0, usage, 0, 0, 0] }

    func matches(_ state: DeviceState) -> Bool {
        guard let function = try? state.function(control), HardwareBinding.equivalent(function, hardwareFunction) else { return false }
        return state.bindings.allSatisfy { binding in
            binding.control == control || binding.function.count != 7 || binding.function[0] != 2 || binding.function[3] != usage
        }
    }
}

/// A default action the receiver can emit directly. Keyboard usages must be
/// unique on the receiver, since modifier flags can include other held keys.
public enum NativeInput: Hashable, Sendable {
    case keyboard(UInt8)
    case mouseButton(MouseButtonAction)

    init?(hardwareFunction: [UInt8]) {
        if let button = MouseButtonAction(hardwareFunction: hardwareFunction) {
            self = .mouseButton(button)
        } else if hardwareFunction.count == 7, hardwareFunction[0] == 2,
                  [1, 2].contains(hardwareFunction[1]), hardwareFunction[2] & 0xf0 == 0,
                  hardwareFunction[4...6].allSatisfy({ $0 == 0 }),
                  HIDKeys.keyCode(for: hardwareFunction[3]) != nil {
            self = .keyboard(hardwareFunction[3])
        } else { return nil }
    }

    static func uniqueInputs(in bindings: [HardwareBinding]) -> [UInt8: Self] {
        var inputs: [UInt8: Self] = [:]
        var counts: [Self: Int] = [:]
        for binding in bindings {
            if let input = Self(hardwareFunction: binding.function) {
                inputs[binding.control] = input
                counts[input, default: 0] += 1
            }
        }
        return inputs.filter { counts[$0.value] == 1 }
    }
}
