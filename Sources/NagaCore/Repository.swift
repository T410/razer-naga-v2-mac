import Foundation

public struct SavedProfile: Codable, Sendable {
    public let profile: MouseProfile
    public let hardware: DeviceState
    public let routes: [LocalRoute]
    public let savedAt: Date
    // Optional so existing profiles and recovery records still decode.
    public let applicationProfiles: [ApplicationProfile]?
    public let applicationTriggers: [ApplicationTrigger]?

    public init(profile: MouseProfile, hardware: DeviceState, routes: [LocalRoute],
                applicationProfiles: [ApplicationProfile] = [], applicationTriggers: [ApplicationTrigger] = []) {
        self.profile = profile; self.hardware = hardware; self.routes = routes; self.savedAt = Date()
        self.applicationProfiles = applicationProfiles.isEmpty ? nil : applicationProfiles
        self.applicationTriggers = applicationTriggers.isEmpty ? nil : applicationTriggers
    }
    public func validate() throws {
        try profile.validate(); try hardware.validate()
        let triggers = applicationTriggers ?? []
        let applicationControls = try ApplicationProfile.controls(in: applicationProfiles ?? [])
        let markerControls = Set(triggers.map(\.control))
        let macAssignments = profile.assignments.filter { $0.action.needsMac && !applicationControls.contains($0.id) }
        let usages = routes.map(\.usage) + triggers.map(\.usage)
        guard profile.serial == hardware.serial, routes.count == macAssignments.count,
              Set(usages).count == usages.count,
              Set(routes.map(\.control)) == Set(macAssignments.map(\.id)),
              triggers.count == markerControls.count, markerControls.isSubset(of: applicationControls),
              Set(nativeInputs(in: hardware).keys) == applicationControls.subtracting(markerControls),
              !profile.assignments.contains(where: { applicationControls.contains($0.id) && $0.action == .original }) else {
            throw NagaError.storage("The Mac profile does not match the mouse backup.")
        }
        for route in routes {
            guard HIDKeys.markerCandidates.contains(route.usage),
                  profile.assignments.first(where: { $0.id == route.control })?.action == .shortcut(route.shortcut),
                  let actual = try? hardware.function(route.control),
                  HardwareBinding.equivalent(actual, [2,2,0,route.usage,0,0,0]) else { throw NagaError.storage("The Mac shortcut's hardware trigger could not be verified.") }
        }
        for trigger in triggers {
            guard HIDKeys.markerCandidates.contains(trigger.usage), trigger.matches(hardware) else {
                throw NagaError.storage("The application profile's hardware trigger could not be verified.")
            }
        }
    }

    public func inputActions(for target: ApplicationProfile.Target?) -> [UInt8: ButtonAction] {
        var actions = Dictionary(uniqueKeysWithValues: routes.map { ($0.usage, ButtonAction.shortcut($0.shortcut)) })
        let overrides = applicationProfiles?.first { $0.id == target }?.assignments ?? []
        for trigger in applicationTriggers ?? [] {
            actions[trigger.usage] = overrides.first { $0.id == trigger.control }?.action
                ?? profile.assignments.first { $0.id == trigger.control }?.action
        }
        return actions
    }

    public func nativeInputActions(for target: ApplicationProfile.Target?) -> [NativeInput: ButtonAction] {
        guard let overrides = applicationProfiles?.first(where: { $0.id == target })?.assignments,
              !overrides.isEmpty else { return [:] }
        let inputs = nativeInputs(in: hardware)
        return Dictionary(uniqueKeysWithValues: overrides.compactMap { assignment in
            inputs[assignment.id].map { ($0, assignment.action) }
        })
    }

    public var routingControlCount: Int { routes.count + applicationControls.count }

    public var canStoreMoreDefaultsOnMouse: Bool {
        guard let applicationTriggers, !applicationTriggers.isEmpty,
              let plan = try? ApplyPlan(profile: profile, baseline: hardware,
                                        applicationProfiles: applicationProfiles ?? []) else { return false }
        let plannedMarkers = Set(plan.applicationTriggers.map(\.control))
        return applicationTriggers.contains { !plannedMarkers.contains($0.control) }
    }

    private var applicationControls: Set<UInt8> {
        Set((applicationProfiles ?? []).flatMap(\.assignments).map(\.id))
    }

    private func nativeInputs(in state: DeviceState) -> [UInt8: NativeInput] {
        let controls = applicationControls.subtracting((applicationTriggers ?? []).map(\.control))
        guard !controls.isEmpty else { return [:] }
        let unique = NativeInput.uniqueInputs(in: state.bindings)
        return Dictionary(uniqueKeysWithValues: profile.assignments.compactMap { assignment in
            let control = assignment.id
            guard controls.contains(control), let input = unique[control],
                  let expected = assignment.action.hardwareFunction, let actual = try? state.function(control),
                  HardwareBinding.equivalent(actual, expected) else { return nil }
            return (control, input)
        })
    }

    public func verifiedSoftwareControls(in state: DeviceState) -> Set<UInt8> {
        guard state.serial == hardware.serial else { return [] }
        let legacy = routes.map { ApplicationTrigger(control: $0.control, usage: $0.usage) }
        let markers = (legacy + (applicationTriggers ?? [])).filter { $0.matches(state) }.map(\.control)
        return Set(markers).union(nativeInputs(in: state).keys)
    }

    public func recognizesDPIConfiguration(_ state: DeviceState) -> Bool {
        guard state.sameBindings(as: hardware), let stages = try? state.dpi.stages else { return false }
        if stages == (try? hardware.dpi.stages) { return true }
        return applicationProfiles?.contains { $0.dpi?.stages == stages } == true
    }
}

public struct DeviceBackup: Codable, Sendable {
    public let hardware: DeviceState
    public let local: SavedProfile?
    public let date: Date
    public init(hardware: DeviceState, local: SavedProfile?) { self.hardware = hardware; self.local = local; self.date = Date() }
    public func validate() throws {
        try hardware.validate()
        if let local {
            try local.validate()
            guard local.profile.serial == hardware.serial else { throw NagaError.storage("The backup belongs to a different mouse.") }
        }
    }
}

public struct RecoveryRecord: Codable, Sendable {
    public let backup: DeviceBackup
    public let operations: [WriteOperation]
    public init(backup: DeviceBackup, operations: [WriteOperation]) { self.backup = backup; self.operations = operations }
}

public final class ProfileRepository: Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func url(_ name: String, serial: String) throws -> URL {
        guard !serial.isEmpty, serial.count <= 64,
              serial.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw NagaError.storage("Invalid mouse identity.") }
        return directory.appendingPathComponent("\(name)-\(serial).json")
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch { throw NagaError.storage("Could not read the saved file: \(url.lastPathComponent). The file is preserved.") }
    }
    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(value)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        guard try Data(contentsOf: url) == bytes else { throw NagaError.storage("The backup could not be verified on disk. No settings were written to the mouse.") }
    }
    public func saved(serial: String) throws -> SavedProfile? {
        let value = try read(SavedProfile.self, at: url("profile", serial: serial))
        try value?.validate()
        return value
    }
    public func save(_ value: SavedProfile) throws {
        try value.validate()
        try write(value, at: url("saved-" + UUID().uuidString, serial: value.profile.serial))
        try write(value, at: url("profile", serial: value.profile.serial))
    }
    public func initial(serial: String) throws -> DeviceBackup? { try read(DeviceBackup.self, at: url("initial", serial: serial)) }
    public func previous(serial: String) throws -> DeviceBackup? { try read(DeviceBackup.self, at: url("previous", serial: serial)) }
    public func ensureInitial(_ backup: DeviceBackup) throws {
        try backup.validate()
        if let existing = try initial(serial: backup.hardware.serial) { try existing.validate(); return }
        try write(backup, at: url("initial", serial: backup.hardware.serial))
    }
    public func backup(_ value: DeviceBackup) throws {
        try ensureInitial(value)
        let archive = "backup-" + UUID().uuidString
        try write(value, at: url(archive, serial: value.hardware.serial))
        try write(value, at: url("previous", serial: value.hardware.serial))
    }
    public func recovery(serial: String) throws -> RecoveryRecord? { try read(RecoveryRecord.self, at: url("recovery", serial: serial)) }
    public func begin(_ record: RecoveryRecord) throws { try write(record, at: url("recovery", serial: record.backup.hardware.serial)) }
    public func finish(serial: String) throws {
        let file = try url("recovery", serial: serial)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public func restoreLocal(_ backup: DeviceBackup) throws {
        if let local = backup.local { try save(local) }
        else {
            let file = try url("profile", serial: backup.hardware.serial)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
