import Foundation

public final class ConfigurationWriter {
    private let io: MouseIO
    private let repository: ProfileRepository
    public init(io: MouseIO, repository: ProfileRepository) { self.io = io; self.repository = repository }

    public func apply(_ profile: MouseProfile, expected: DeviceState, applicationProfiles: [ApplicationProfile] = []) throws -> SavedProfile {
        try profile.validate()
        let current = try DeviceState.read(from: io)
        guard current.sameConfiguration(as: expected) else { throw NagaError.invalid("The mouse settings have changed. Click Refresh to read the current settings.") }
        guard try repository.recovery(serial: current.serial) == nil else { throw NagaError.storage("Restore the interrupted operation's backup first.") }
        let plan = try ApplyPlan(profile: profile, baseline: current, applicationProfiles: applicationProfiles)
        let local = try repository.saved(serial: current.serial)
        let backupState: DeviceState
        if let local, local.recognizesDPIConfiguration(current), !current.sameConfiguration(as: local.hardware) {
            backupState = local.hardware
        } else {
            backupState = current
        }
        let backup = DeviceBackup(hardware: backupState, local: local)
        try repository.backup(backup)
        // All requested assignments, including hardware actions, are backed up on this Mac.
        // The committed profile is only replaced after complete hardware verification.
        let record = RecoveryRecord(backup: backup, operations: plan.operations)
        try repository.begin(record)
        var attempted: [WriteOperation] = []
        do {
            for operation in plan.operations {
                attempted.append(operation) // A failed transfer may still have reached flash.
                try send(operation, serial: current.serial)
            }
            let after = try DeviceState.read(from: io)
            guard after.serial == current.serial else { throw NagaError.unavailable("The mouse identity changed during the operation.") }
            let saved = SavedProfile(profile: profile, hardware: after, routes: plan.routes,
                                     applicationProfiles: applicationProfiles, applicationTriggers: plan.applicationTriggers)
            try repository.save(saved)
            try repository.finish(serial: current.serial)
            return saved
        } catch {
            let originalError = error
            do {
                try rollback(attempted, to: current)
                try repository.restoreLocal(backup)
                try repository.finish(serial: current.serial)
            } catch {
                throw NagaError.io("The operation failed: \(originalError.localizedDescription)\nRestore also failed. The backup is preserved; use Restore when the mouse reconnects.\n\(error.localizedDescription)")
            }
            throw NagaError.io("The operation failed; previous settings were restored.\n\(originalError.localizedDescription)")
        }
    }

    /// A focus change uses the same verified DPI commands as Apply. Keep the
    /// user's previous-settings backup intact and recover to the saved default.
    public func switchDPI(to dpi: DPISettings, saved: SavedProfile, expected: DeviceState) throws -> DeviceState {
        try dpi.validate()
        let current = try DeviceState.read(from: io)
        guard current.sameConfiguration(as: expected), saved.recognizesDPIConfiguration(current) else {
            throw NagaError.invalid("The mouse settings have changed. Click Refresh to read the current settings.")
        }
        guard try repository.recovery(serial: current.serial) == nil else {
            throw NagaError.storage("Restore the interrupted operation's backup first.")
        }
        let stage = dpi.stages[dpi.active - 1]
        var operations: [WriteOperation] = []
        if try current.dpi != dpi { operations.append(.stages(try DPIWire.encode(dpi, preserving: current.stageBytes))) }
        if !operations.isEmpty || current.dpiX != stage.x || current.dpiY != stage.y {
            operations.append(.currentDPI(stage.x, stage.y))
        }
        guard !operations.isEmpty else { return current }
        let backup = DeviceBackup(hardware: saved.hardware, local: saved)
        try repository.begin(RecoveryRecord(backup: backup, operations: operations))
        var attempted: [WriteOperation] = []
        do {
            for operation in operations {
                attempted.append(operation)
                try send(operation, serial: current.serial)
            }
            let after = try DeviceState.read(from: io)
            guard after.sameBindings(as: current), try after.dpi == dpi,
                  after.dpiX == stage.x, after.dpiY == stage.y else {
                throw NagaError.protocolError("The profile's DPI stages could not be verified.")
            }
            try repository.finish(serial: current.serial)
            return after
        } catch {
            let failure = error
            try rollback(attempted, to: current)
            try repository.finish(serial: current.serial)
            throw failure
        }
    }

    public func restore(_ backup: DeviceBackup) throws -> DeviceState {
        try backup.validate()
        let current = try DeviceState.read(from: io)
        guard current.serial == backup.hardware.serial else { throw NagaError.invalid("The backup does not belong to this mouse.") }
        let target = backup.hardware
        var operations = try DeviceState.controlIDs.compactMap { id -> WriteOperation? in
            let before = try current.function(id), after = try target.function(id)
            return HardwareBinding.equivalent(before, after) ? nil : .binding(id, after)
        }
        if try current.dpi != target.dpi { operations.append(.stages(target.stageBytes)) }
        if current.dpiX != target.dpiX || current.dpiY != target.dpiY || operations.contains(where: { if case .stages = $0 { return true }; return false }) {
            operations.append(.currentDPI(target.dpiX, target.dpiY))
        }
        // Keep an existing crash-recovery record until a complete restore succeeds.
        if try repository.recovery(serial: current.serial) == nil {
            try repository.begin(RecoveryRecord(backup: DeviceBackup(hardware: current, local: repository.saved(serial: current.serial)), operations: operations))
        }
        for operation in operations { try send(operation, serial: current.serial) }
        let actual = try DeviceState.read(from: io)
        guard actual.sameConfiguration(as: target), actual.dpiX == target.dpiX, actual.dpiY == target.dpiY else { throw NagaError.protocolError("Restore could not be verified. The backup is preserved.") }
        try repository.restoreLocal(backup)
        try repository.finish(serial: current.serial)
        return actual
    }

    private func send(_ operation: WriteOperation, serial: String) throws {
        let command = operation.command
        try command.validate(allowWrites: true)
        try verifyIdentity(serial)
        _ = try io.execute(command, allowWrites: true)
        try verifyIdentity(serial)
        try operation.verify(using: io)
    }
    private func verifyIdentity(_ expectedSerial: String) throws {
        let bytes = try io.execute(.serial, allowWrites: false)
        guard String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .ascii) == expectedSerial else {
            throw NagaError.unavailable("The mouse identity could not be verified. The operation was stopped; reconnect the same mouse.")
        }
    }
    private func rollback(_ operations: [WriteOperation], to state: DeviceState) throws {
        // Confirm identity before any rollback, including after a disconnect/replug.
        try verifyIdentity(state.serial)
        for operation in operations.reversed() { try send(operation.undo(in: state), serial: state.serial) }
        if operations.contains(where: { if case .stages = $0 { return true }; return false }) {
            try send(.currentDPI(state.dpiX, state.dpiY), serial: state.serial)
        }
    }
}
