import Foundation
import Testing
@testable import NagaCore

private func fixture() throws -> DeviceState {
    let settings = DPISettings(stages: [400,800,1600,3200,6400].map { DPIStage(x: $0) }, active: 3)
    let bytes = try DPIWire.encode(settings, preserving: .init(repeating: 0, count: 38))
    let bindings = DeviceState.controlIDs.map { id -> HardwareBinding in
        if id >= 0x40 { return HardwareBinding(control: id, function: [2,2,0,UInt8(0x1e + (id - 0x40) % 10),0,0,0]) }
        if id == 0x0b || id == 0x0c { return HardwareBinding(control: id, function: [6,1,id == 0x0b ? 1 : 2,0,0,0,0]) }
        return HardwareBinding(control: id, function: [0x0e,3,id == 0x34 ? 0x68 : 0x69,0,0x14,0,0])
    }
    return DeviceState(serial: "TEST12345", bindings: bindings, stageBytes: bytes, dpiX: 1600, dpiY: 1600, mode: 0)
}

private final class SimulatedMouse: MouseIO {
    var state: DeviceState
    var writes: [MouseCommand] = []
    var failWrite: Int?
    var failWritesFrom: Int?
    var beforeWrite: (() throws -> Void)?
    var afterWrite: ((SimulatedMouse, MouseCommand) -> Void)?
    var readTransform: ((MouseCommand, [UInt8]) -> [UInt8])?
    init(_ state: DeviceState) { self.state = state }
    func execute(_ command: MouseCommand, allowWrites: Bool) throws -> [UInt8] {
        try command.validate(allowWrites: allowWrites)
        if command.isRead {
            let answer: [UInt8]
            switch (command.group, command.id) {
            case (0, 0x82): answer = Array(state.serial.utf8) + Array(repeating: 0, count: 22 - state.serial.utf8.count)
            case (0, 0x84): answer = [state.mode, 0]
            case (4, 0x85): answer = [0,UInt8(state.dpiX >> 8),UInt8(state.dpiX & 255),UInt8(state.dpiY >> 8),UInt8(state.dpiY & 255),0,0]
            case (4, 0x86): answer = state.stageBytes
            case (2, 0x8c): answer = try [command.payload[0],command.payload[1],0] + state.function(command.payload[1])
            default: throw NagaError.protocolError("Unexpected read")
            }
            return readTransform?(command, answer) ?? answer
        }
        try beforeWrite?()
        writes.append(command)
        if let failWritesFrom, writes.count >= failWritesFrom { throw NagaError.io("Connection lost") }
        switch (command.group, command.id) {
        case (2, 12):
            let index = state.bindings.firstIndex { $0.control == command.payload[1] }!
            state.bindings[index].function = Array(command.payload.dropFirst(3))
        case (4, 6):
            state.stageBytes = command.payload
            let dpi = try state.dpi; state.dpiX = dpi.stages[dpi.active - 1].x; state.dpiY = dpi.stages[dpi.active - 1].y
        case (4, 5):
            state.dpiX = Int(command.payload[1]) << 8 | Int(command.payload[2]); state.dpiY = Int(command.payload[3]) << 8 | Int(command.payload[4])
        default: throw NagaError.invalid("Unexpected write")
        }
        afterWrite?(self, command)
        if failWrite == writes.count { failWrite = nil; throw NagaError.io("Simulated disconnect after command reached device") }
        return command.payload
    }
}

private func repository() throws -> ProfileRepository {
    try ProfileRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("NagaTests-" + UUID().uuidString))
}

@Test(arguments: MouseButtonAction.allCases)
func nativeMouseButtonsUseOrdinalsRatherThanUSBBitmasks(button: MouseButtonAction) throws {
    let left = button == .button4
    let expected: [UInt8] = left ? [1,1,4,0,0,0,0] : [1,1,5,0,0,0,0]
    #expect(button.hardwareFunction == expected)
    let control: UInt8 = left ? 0x34 : 0x35
    let command = WriteOperation.binding(control, button.hardwareFunction).command
    try command.validate(allowWrites: true)
    let packet = command.packet()
    #expect(Array(packet.prefix(18)) == [0,0x1f,0,0,0,10,2,12,1,control,0] + expected)
    #expect(packet[88] == 0x35)
    #expect(MouseButtonAction(hardwareFunction: expected) == button)
    #expect(!ButtonAction.mouseButton(button).needsMac)
}

private func mouseTiltProfile(_ state: DeviceState) throws -> MouseProfile {
    var profile = try state.makeProfile(label: { "Key \($0)" })
    for (id, button): (UInt8, MouseButtonAction) in [(0x34, .button4), (0x35, .button5)] {
        let index = try #require(profile.assignments.firstIndex(where: { $0.id == id }))
        profile.assignments[index].action = .mouseButton(button)
    }
    return profile
}

@Test func applicationOverridesShareADeviceTriggerAndRestoreTheDefaultOutsideTheApp() throws {
    let state = try fixture()
    let mouse = SimulatedMouse(state)
    let repo = try repository()
    let writer = ConfigurationWriter(io: mouse, repository: repo)
    var profile = try state.makeProfile(label: { "Key \($0)" })
    let control = profile.assignments[0].id
    let original = profile.assignments[0].action
    let key = ButtonAction.shortcut(Shortcut(keyCode: 14, keyLabel: "E"))
    var skyrim = ApplicationProfile(target: .wineExecutable("skyrimse.exe"), name: "Skyrim (Wine)")
    skyrim.assignments = [Assignment(id: control, action: key)]
    var other = ApplicationProfile(target: .bundleIdentifier("com.example.Editor"), name: "Editor")
    other.assignments = [Assignment(id: control, action: .disabled)]

    let saved = try writer.apply(profile, expected: state, applicationProfiles: [skyrim, other])
    let triggers = try #require(saved.applicationTriggers)
    let marker = try #require(triggers.first?.usage)
    #expect(triggers.count == 1)
    #expect(mouse.writes.count == 1)
    #expect(saved.inputActions(for: skyrim.id) == [marker: key])
    #expect(saved.inputActions(for: other.id) == [marker: .disabled])
    #expect(saved.inputActions(for: nil) == [marker: original])
    #expect(try repo.saved(serial: state.serial)?.applicationProfiles == [skyrim, other])

    let fallback = ButtonAction.shortcut(Shortcut(keyCode: 8, modifiers: .fn, keyLabel: "C"))
    profile.assignments[0].action = fallback
    skyrim.assignments[0].action = .mouseButton(.button4)
    let updated = try writer.apply(profile, expected: saved.hardware, applicationProfiles: [skyrim, other])
    #expect(mouse.writes.count == 1)
    #expect(updated.routes.isEmpty)
    #expect(updated.inputActions(for: nil) == [marker: fallback])
    #expect(updated.inputActions(for: skyrim.id) == [marker: .mouseButton(.button4)])

    let previous = try #require(try repo.previous(serial: state.serial))
    _ = try writer.restore(previous)
    #expect(try repo.saved(serial: state.serial)?.inputActions(for: skyrim.id) == [marker: key])
    let initial = try #require(try repo.initial(serial: state.serial))
    let restored = try writer.restore(initial)
    #expect(restored.sameConfiguration(as: state))
    #expect(try repo.saved(serial: state.serial) == nil)
}

@Test func invalidApplicationOverridesFailBeforeAnyHardwareWrite() throws {
    let state = try fixture()
    let mouse = SimulatedMouse(state)
    let writer = ConfigurationWriter(io: mouse, repository: try repository())
    let profile = try state.makeProfile(label: { "Key \($0)" })
    var skyrim = ApplicationProfile(target: .wineExecutable("skyrimse.exe"), name: "Skyrim (Wine)")
    skyrim.assignments = [Assignment(id: 0x34, action: .disabled)]
    #expect(throws: NagaError.self) { try writer.apply(profile, expected: state, applicationProfiles: [skyrim]) }
    skyrim.assignments = [Assignment(id: 0x40, action: .original)]
    #expect(throws: NagaError.self) { try writer.apply(profile, expected: state, applicationProfiles: [skyrim]) }
    #expect(mouse.writes.isEmpty)
}

@Test func nativeDefaultMigrationKeepsProfileOverridesOnTheMac() throws {
    var state = try fixture()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    let shortcut = Shortcut(keyCode: 123, modifiers: .control, keyLabel: "←")
    let gameAction = ButtonAction.shortcut(Shortcut(keyCode: 38, keyLabel: "J"))
    let otherAction = ButtonAction.shortcut(Shortcut(keyCode: 8, keyLabel: "C"))
    let disabled: UInt8 = 0x40
    let buttonTen: UInt8 = 0x49
    for (control, action, marker): (UInt8, ButtonAction, UInt8) in [
        (disabled, .disabled, 0x6d), (buttonTen, .shortcut(shortcut), 0x40)
    ] {
        let index = try #require(profile.assignments.firstIndex { $0.id == control })
        profile.assignments[index].action = action
        let binding = try #require(state.bindings.firstIndex { $0.control == control })
        state.bindings[binding].function = [2, 2, 0, marker, 0, 0, 0]
    }
    var game = ApplicationProfile(target: .bundleIdentifier("com.example.Game"), name: "Game")
    game.assignments = [Assignment(id: disabled, action: otherAction), Assignment(id: buttonTen, action: gameAction)]
    let legacy = SavedProfile(profile: profile, hardware: state, routes: [], applicationProfiles: [game], applicationTriggers: [
        ApplicationTrigger(control: disabled, usage: 0x6d), ApplicationTrigger(control: buttonTen, usage: 0x40)
    ])
    try legacy.validate()
    #expect(legacy.canStoreMoreDefaultsOnMouse)
    let repo = try repository()
    try repo.save(legacy)
    let mouse = SimulatedMouse(state)
    let writer = ConfigurationWriter(io: mouse, repository: repo)

    let saved = try writer.apply(profile, expected: state, applicationProfiles: [game])
    #expect(mouse.writes.count == 1)
    #expect(mouse.writes.first?.payload[1] == buttonTen)
    #expect(try saved.hardware.function(buttonTen) == shortcut.hardwareFunction)
    #expect(!saved.canStoreMoreDefaultsOnMouse)
    #expect(saved.inputActions(for: nil) == [0x6d: .disabled])
    #expect(saved.nativeInputActions(for: nil).isEmpty)
    #expect(saved.nativeInputActions(for: game.id) == [.keyboard(0x50): gameAction])
    #expect(saved.verifiedSoftwareControls(in: saved.hardware) == [disabled, buttonTen])

    game.assignments[1].action = otherAction
    let updated = try writer.apply(profile, expected: saved.hardware, applicationProfiles: [game])
    #expect(mouse.writes.count == 1)
    #expect(updated.nativeInputActions(for: game.id) == [.keyboard(0x50): otherAction])
}

@Test func focusChangesSwapTheWholeDPITableAndKeepTheSavedDefaultAndPreviousBackup() throws {
    let state = try fixture()
    let mouse = SimulatedMouse(state)
    let repo = try repository()
    let writer = ConfigurationWriter(io: mouse, repository: repo)
    let profile = try state.makeProfile(label: { "Key \($0)" })
    var app = ApplicationProfile(target: .bundleIdentifier("com.example.Game"), name: "Game")
    let custom = DPISettings(stages: [DPIStage(x: 900), DPIStage(x: 2100, y: 1900)], active: 2)
    app.dpi = custom
    let saved = try writer.apply(profile, expected: state, applicationProfiles: [app])
    #expect(try repo.saved(serial: state.serial)?.applicationProfiles?.first?.dpi == custom)
    let previousDate = try repo.previous(serial: state.serial)?.date

    let inGame = try writer.switchDPI(to: custom, saved: saved, expected: saved.hardware)
    #expect(try inGame.dpi == custom)
    #expect(inGame.dpiX == 2100 && inGame.dpiY == 1900)
    #expect(inGame.bindings == saved.hardware.bindings)
    #expect(saved.recognizesDPIConfiguration(inGame))
    let writes = mouse.writes.count
    _ = try writer.switchDPI(to: custom, saved: saved, expected: inGame)
    #expect(mouse.writes.count == writes)

    let defaultState = try writer.switchDPI(to: profile.dpi, saved: saved, expected: inGame)
    #expect(try defaultState.dpi == profile.dpi)
    #expect(defaultState.dpiX == state.dpiX && defaultState.dpiY == state.dpiY)
    #expect(try repo.previous(serial: state.serial)?.date == previousDate)
    #expect(try repo.saved(serial: state.serial)?.hardware == saved.hardware)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func failedApplicationDPISwitchRestoresThePreviousTableAndActiveStage() throws {
    let state = try fixture()
    let mouse = SimulatedMouse(state)
    let repo = try repository()
    let writer = ConfigurationWriter(io: mouse, repository: repo)
    let profile = try state.makeProfile(label: { "Key \($0)" })
    var app = ApplicationProfile(target: .bundleIdentifier("com.example.Game"), name: "Game")
    let custom = DPISettings(stages: [DPIStage(x: 900)], active: 1)
    app.dpi = custom
    let saved = try writer.apply(profile, expected: state, applicationProfiles: [app])
    mouse.failWrite = mouse.writes.count + 2

    #expect(throws: NagaError.self) { try writer.switchDPI(to: custom, saved: saved, expected: saved.hardware) }
    #expect(mouse.state == saved.hardware)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func mouseTiltsWriteOnlyTwoBindingsAndSurviveReloading() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    let profile = try mouseTiltProfile(state)
    let saved = try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state)
    #expect(mouse.writes.map { $0.payload[1] } == [0x34, 0x35])
    #expect(mouse.writes.allSatisfy { $0.group == 2 && $0.id == 0x0c })
    #expect(try mouse.state.function(0x34) == [1,1,4,0,0,0,0])
    #expect(try mouse.state.function(0x35) == [1,1,5,0,0,0,0])
    for id in DeviceState.controlIDs where id != 0x34 && id != 0x35 {
        #expect(try mouse.state.function(id) == state.function(id))
    }
    #expect(mouse.state.stageBytes == state.stageBytes)
    #expect(mouse.state.dpiX == state.dpiX && mouse.state.dpiY == state.dpiY)
    #expect(saved.routes.isEmpty)
    let loaded = try ProfileRepository(directory: repo.directory).saved(serial: state.serial)
    #expect(loaded?.profile == profile)
    let imported = try mouse.state.makeProfile(label: { "Key \($0)" })
    #expect(imported.assignments.first(where: { $0.id == 0x34 })?.action == .mouseButton(.button4))
    #expect(imported.assignments.first(where: { $0.id == 0x35 })?.action == .mouseButton(.button5))
    #expect(try ApplyPlan(profile: profile, baseline: mouse.state).operations.isEmpty)
}

@Test func partialMouseTiltWritesRestoreBothHardwareAndTheMacProfile() throws {
    for position in 1...2 {
        let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
        let original = SavedProfile(profile: try state.makeProfile(label: { "Key \($0)" }), hardware: state, routes: [])
        try repo.save(original)
        mouse.failWrite = position
        #expect(throws: (any Error).self) {
            try ConfigurationWriter(io: mouse, repository: repo).apply(mouseTiltProfile(state), expected: state)
        }
        #expect(mouse.state == state)
        #expect(try repo.saved(serial: state.serial)?.profile == original.profile)
        #expect(try repo.recovery(serial: state.serial) == nil)
    }
}

@Test func nativeMouseBindingsCoexistWithMacOnlyShortcutRoutes() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try mouseTiltProfile(state)
    profile.assignments[0].action = .shortcut(Shortcut(keyCode: 8, modifiers: [.fn,.command], keyLabel: "C"))
    let saved = try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state)
    #expect(saved.routes.count == 1)
    #expect(saved.routes[0].control == 0x40)
    #expect(try mouse.state.function(0x34) == [1,1,4,0,0,0,0])
    #expect(try mouse.state.function(0x35) == [1,1,5,0,0,0,0])
    try saved.validate()
}

@Test func unrecognizedMouseDescriptorsArePreservedRatherThanGuessed() throws {
    let descriptors: [[UInt8]] = [[1,1,8,0,0,0,0], [1,1,0x10,0,0,0,0], [1,1,4,1,0,0,0], [1,2,4,0,0,0,0]]
    for descriptor in descriptors {
        #expect(MouseButtonAction(hardwareFunction: descriptor) == nil)
        var state = try fixture()
        let index = try #require(state.bindings.firstIndex(where: { $0.control == 0x34 }))
        state.bindings[index].function = descriptor
        let imported = try state.makeProfile(label: { "Key \($0)" })
        #expect(imported.assignments.first(where: { $0.id == 0x34 })?.action == .original)
        #expect(try ApplyPlan(profile: imported, baseline: state).operations.isEmpty)
    }
}

@Test func firmwareResetModeAndUnrelatedControlsAreBlocked() throws {
    let commands = [
        MouseCommand(group: 0, id: 4, payload: [3,0]),
        MouseCommand(group: 0, id: 8, payload: [1]),
        MouseCommand(group: 2, id: 12, payload: [1,1,0,1,1,1,0,0,0,0]),
        MouseCommand(group: 2, id: 12, payload: [1,0x40,1,2,2,0,4,0,0,0])
    ]
    for command in commands { #expect(throws: (any Error).self) { try command.validate(allowWrites: true) } }
    let allowed = WriteOperation.binding(0x40, [2,2,8,6,0,0,0]).command
    #expect(throws: (any Error).self) { try allowed.validate(allowWrites: false) }
}

@Test func responseRejectsCorruptionAndAnotherControl() throws {
    let command = MouseCommand.binding(0x40)
    var packet = command.packet(); packet[0] = 2; packet[12] ^= 1
    #expect(throws: (any Error).self) { try command.response(packet) }
    packet[88] = MouseCommand.checksum(packet)
    #expect(try command.response(packet).count == 10)
    packet[9] = 0x41; packet[88] = MouseCommand.checksum(packet)
    #expect(command.shouldPoll(packet))
    #expect(throws: (any Error).self) { try command.response(packet) }
}

@Test func dpiStagesRoundTripAndPreserveReservedBytes() throws {
    var original = [UInt8](repeating: 0, count: 38); original[8] = 0x42
    let settings = DPISettings(stages: [800,1200,1600,2400,3200].map { DPIStage(x: $0) }, active: 2)
    let encoded = try DPIWire.encode(settings, preserving: original)
    #expect(encoded[8] == 0x42)
    #expect(try DPIWire.decode(encoded) == settings)
    #expect(throws: (any Error).self) { try DPISettings(stages: [DPIStage(x: 0)], active: 1).validate() }
    #expect(throws: (any Error).self) { try DPISettings(stages: Array(repeating: DPIStage(x: 800), count: 6), active: 1).validate() }
}

@Test func hybridPlanUsesIndependentMarkersAndPreservesDirectBindings() throws {
    let state = try fixture()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .shortcut(Shortcut(keyCode: 105, keyLabel: "F13"))
    profile.assignments[1].action = .shortcut(Shortcut(keyCode: 8, modifiers: [.fn,.command], keyLabel: "C"))
    profile.assignments[2].action = .shortcut(Shortcut(keyCode: 9, modifiers: .fn, keyLabel: "V"))
    let plan = try ApplyPlan(profile: profile, baseline: state)
    #expect(plan.routes.count == 2)
    #expect(Set(plan.routes.map(\.usage)).count == 2)
    #expect(!plan.routes.contains { $0.usage == 0x68 })
    #expect(plan.operations.contains(.binding(0x40, [2,2,0,0x68,0,0,0])))
}

@Test func backupsAndRecoveryExistBeforeFirstHardwareWriteAndFullProfileIsCommitted() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .shortcut(Shortcut(keyCode: 8, modifiers: .command, keyLabel: "C"))
    mouse.beforeWrite = { () throws -> Void in
        let initial = try repo.initial(serial: state.serial)
        let previous = try repo.previous(serial: state.serial)
        let recovery = try repo.recovery(serial: state.serial)
        #expect(initial?.hardware == state)
        #expect(previous?.hardware == state)
        #expect(recovery != nil)
    }
    let result = try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state)
    #expect(result.profile == profile)
    #expect(try repo.saved(serial: state.serial)?.profile == profile)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func uncertainWriteRollsBackAllAttemptedSettings() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .disabled; profile.assignments[1].action = .disabled
    mouse.failWrite = 2
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.state == state)
    #expect(try repo.saved(serial: state.serial) == nil)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func dpiFailureRestoresCurrentDPIAndTheOriginalStageTable() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.dpi = DPISettings(stages: [800,1200,2400].map { DPIStage(x: $0) }, active: 2)
    mouse.failWrite = 2
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.state == state)
}

@Test func corruptBackupBlocksAllHardwareWrites() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    try Data("broken".utf8).write(to: repo.directory.appendingPathComponent("initial-\(state.serial).json"))
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.writes.isEmpty)
}

@Test func changedOrDifferentMouseIsNeverOverwritten() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    mouse.state.serial = "OTHER"
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.writes.isEmpty)
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).restore(DeviceBackup(hardware: state, local: nil)) }
    #expect(mouse.writes.isEmpty)
}

@Test func restoreReturnsHardwareAndMacProfileToPreviousState() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    let writer = ConfigurationWriter(io: mouse, repository: repo)
    _ = try writer.apply(profile, expected: state)
    let previousValue = try repo.previous(serial: state.serial)
    let previous = try #require(previousValue)
    let restored = try writer.restore(previous)
    #expect(restored == state)
    #expect(try repo.saved(serial: state.serial) == nil)
}

@Test func unknownDeviceModeAndIncompleteBackupsAreRejected() throws {
    var state = try fixture(); state.mode = 3
    #expect(throws: (any Error).self) { try state.validate() }
    state.mode = 0; state.bindings.removeFirst()
    #expect(throws: (any Error).self) { try state.validate() }
}

@Test func interruptedRollbackKeepsRecoveryAndCanBeRestoredInANewSession() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .disabled; profile.assignments[1].action = .disabled
    mouse.failWritesFrom = 2
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    let recordValue = try repo.recovery(serial: state.serial)
    let record = try #require(recordValue)
    #expect(mouse.state != state)
    let reconnected = SimulatedMouse(mouse.state)
    let restored = try ConfigurationWriter(io: reconnected, repository: repo).restore(record.backup)
    #expect(restored == state)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func invalidLocalBackupIsRejectedBeforeRestoreWritesAnything() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var invalid = try state.makeProfile(label: { "Key \($0)" }); invalid.dpi.active = 0
    let saved = SavedProfile(profile: invalid, hardware: state, routes: [])
    let backup = DeviceBackup(hardware: state, local: saved)
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).restore(backup) }
    #expect(mouse.writes.isEmpty)
}

@Test func shortcutWritePacketMatchesKnownWireBytes() throws {
    // Independently specified wire example: stored side button 1 -> Command-Shift-C.
    let command = WriteOperation.binding(0x40, [2,2,0x0a,0x06,0,0,0]).command
    try command.validate(allowWrites: true)
    let packet = command.packet()
    #expect(packet.count == 90)
    #expect(Array(packet.prefix(15)) == [0,0x1f,0,0,0,10,2,12,1,0x40,0,2,2,0x0a,0x06])
    #expect(packet[15..<88].allSatisfy { $0 == 0 })
    #expect(packet[88] == 0x49)
    #expect(packet[89] == 0)
}

private func fullyChangedProfile(_ state: DeviceState) throws -> MouseProfile {
    var profile = try state.makeProfile(label: { "Key \($0)" })
    let codes: [UInt16] = [8,9,0,1,2,3,5,4,34,38,40,37,46,45]
    for i in profile.assignments.indices {
        profile.assignments[i].action = .shortcut(Shortcut(keyCode: codes[i], modifiers: [.command,.shift], keyLabel: "Test \(i)"))
    }
    profile.dpi = DPISettings(stages: [DPIStage(x: 100), DPIStage(x: 1200, y: 1400), DPIStage(x: 2400), DPIStage(x: 30000)], active: 2)
    return profile
}

@Test func writesAllFourteenControlsAndDPIAndSavesTheEntireMacCopy() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    let profile = try fullyChangedProfile(state)
    let result = try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state)
    let usages: [UInt8] = [6,25,4,22,7,9,10,11,12,13,14,15,16,17]
    for (i, control) in MouseControl.all.enumerated() {
        #expect(try mouse.state.function(control.id) == [2,2,0x0a,usages[i],0,0,0])
    }
    #expect(try mouse.state.dpi == profile.dpi)
    #expect(mouse.state.dpiX == 1200 && mouse.state.dpiY == 1400)
    #expect(mouse.writes.count == 16)
    #expect(mouse.writes.filter { $0.group == 2 }.allSatisfy { MouseControl.editableIDs.contains($0.payload[1]) })
    #expect(try mouse.state.function(0x0b) == state.function(0x0b))
    #expect(try mouse.state.function(0x0c) == state.function(0x0c))
    let saved = try repo.saved(serial: state.serial)
    #expect(saved?.profile == profile)
    #expect(saved?.hardware == mouse.state)
    #expect(result.routes.isEmpty)
}

@Test func mixedHardwareAndMacAssignmentsSurviveSavingAndReloading() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .shortcut(Shortcut(keyCode: 8, modifiers: .command, keyLabel: "C"))
    profile.assignments[1].action = .shortcut(Shortcut(keyCode: 9, modifiers: [.fn,.command], keyLabel: "V"))
    profile.assignments[12].action = .shortcut(Shortcut(keyCode: 40, modifiers: .fn, keyLabel: "K"))
    let result = try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state)
    #expect(result.routes.count == 2)
    #expect(Set(result.routes.map(\.usage)).count == 2)
    #expect(try mouse.state.function(0x40) == [2,2,8,6,0,0,0])
    for route in result.routes {
        #expect(try mouse.state.function(route.control) == [2,2,0,route.usage,0,0,0])
    }
    let reopened = try ProfileRepository(directory: repo.directory)
    #expect(try reopened.saved(serial: state.serial)?.profile == profile)
    #expect(try reopened.saved(serial: state.serial)?.routes == result.routes)
}

@Test func unchangedFactoryBindingsDoNotCauseFlashWrites() throws {
    var state = try fixture()
    for i in state.bindings.indices where state.bindings[i].function[0] == 2 { state.bindings[i].function[1] = 1 }
    let mouse = SimulatedMouse(state), repo = try repository()
    let profile = try state.makeProfile(label: { "Key \($0)" })
    _ = try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state)
    #expect(mouse.writes.isEmpty)
    #expect(mouse.state == state)
    #expect(try repo.saved(serial: state.serial)?.profile == profile)
}

private func checkIncorrectBankReadback(_ bank: UInt8) throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    var corrupted = false
    mouse.readTransform = { [weak mouse] command, answer in
        guard mouse?.writes.count == 1, command.group == 2, command.id == 0x8c,
              command.payload[0] == bank, !corrupted else { return answer }
        corrupted = true
        var wrong = answer; wrong[6] ^= 1; return wrong
    }
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(corrupted)
    #expect(mouse.state == state)
    #expect(try repo.saved(serial: state.serial) == nil)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func mismatchedStoredBankReadbackRollsBack() throws { try checkIncorrectBankReadback(1) }
@Test func mismatchedActiveBankReadbackRollsBack() throws { try checkIncorrectBankReadback(0) }

@Test func mismatchedDPIReadbackRollsBackStageTableAndCurrentDPI() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.dpi = DPISettings(stages: [800,1200,2400].map { DPIStage(x: $0) }, active: 2)
    var corrupted = false
    mouse.readTransform = { [weak mouse] command, answer in
        guard mouse?.writes.count == 1, command.group == 4, command.id == 0x86, !corrupted else { return answer }
        corrupted = true; var wrong = answer; wrong[1] = 1; return wrong
    }
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(corrupted)
    #expect(mouse.state == state)
    #expect(try repo.saved(serial: state.serial) == nil)
}

@Test func everyPossiblePartialWritePositionRestoresTheOriginalConfiguration() throws {
    let state = try fixture(), profile = try fullyChangedProfile(state)
    let count = try ApplyPlan(profile: profile, baseline: state).operations.count
    #expect(count == 16)
    for position in 1...count {
        let mouse = SimulatedMouse(state), repo = try repository()
        mouse.failWrite = position
        #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
        #expect(mouse.state == state, "Rollback failed at write \(position)")
        #expect(try repo.saved(serial: state.serial) == nil)
        #expect(try repo.recovery(serial: state.serial) == nil)
    }
}

@Test func backupStorageFailurePreventsEveryHardwareWrite() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    try FileManager.default.createDirectory(at: repo.directory.appendingPathComponent("previous-\(state.serial).json"), withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.writes.isEmpty)
    #expect(mouse.state == state)
}

@Test func profileCommitFailureRollsBackAlreadyWrittenHardware() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    mouse.beforeWrite = { () throws -> Void in
        if mouse.writes.isEmpty {
            try FileManager.default.createDirectory(at: repo.directory.appendingPathComponent("profile-\(state.serial).json"), withIntermediateDirectories: false)
        }
    }
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.state == state)
    #expect(try repo.saved(serial: state.serial) == nil)
    #expect(try repo.recovery(serial: state.serial) == nil)
}

@Test func aMouseIdentityChangeBetweenWritesStopsFurtherWritesAndRetainsRecovery() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .disabled; profile.assignments[1].action = .disabled
    mouse.afterWrite = { device, _ in if device.writes.count == 1 { device.state.serial = "OTHER" } }
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.writes.count == 1)
    #expect(try repo.saved(serial: state.serial) == nil)
    #expect(try repo.recovery(serial: state.serial) != nil)
}

@Test func pendingRecoveryBlocksANewApply() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" }); profile.assignments[0].action = .disabled
    try repo.begin(RecoveryRecord(backup: DeviceBackup(hardware: state, local: nil), operations: [.binding(0x40, .init(repeating: 0, count: 7))]))
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.writes.isEmpty)
    #expect(try repo.recovery(serial: state.serial) != nil)
}

@Test func restoreAlsoRestoresPreviouslySavedMacOnlyAssignments() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    let writer = ConfigurationWriter(io: mouse, repository: repo)
    var first = try state.makeProfile(label: { "Key \($0)" })
    first.assignments[0].action = .shortcut(Shortcut(keyCode: 8, modifiers: [.fn,.command], keyLabel: "C"))
    let firstResult = try writer.apply(first, expected: state)
    let firstHardware = mouse.state
    var second = first; second.assignments[0].action = .disabled
    _ = try writer.apply(second, expected: firstHardware)
    let backupValue = try repo.previous(serial: state.serial)
    let backup = try #require(backupValue)
    let restored = try writer.restore(backup)
    #expect(restored == firstHardware)
    #expect(try repo.saved(serial: state.serial)?.profile == first)
    #expect(try repo.saved(serial: state.serial)?.routes == firstResult.routes)
    #expect(try repo.initial(serial: state.serial)?.hardware == state)
}

@Test func identityChangeDuringRestoreStopsBeforeAnotherWrite() throws {
    let original = try fixture()
    var modified = original
    modified.bindings[0].function = .init(repeating: 0, count: 7)
    modified.bindings[1].function = .init(repeating: 0, count: 7)
    let mouse = SimulatedMouse(modified), repo = try repository()
    mouse.afterWrite = { device, _ in if device.writes.count == 1 { device.state.serial = "OTHER" } }
    #expect(throws: (any Error).self) {
        try ConfigurationWriter(io: mouse, repository: repo).restore(DeviceBackup(hardware: original, local: nil))
    }
    #expect(mouse.writes.count == 1)
    #expect(try repo.recovery(serial: original.serial) != nil)
}

@Test func identityChangeDuringRollbackStopsRollbackAndKeepsItsBackup() throws {
    let state = try fixture(), mouse = SimulatedMouse(state), repo = try repository()
    var profile = try state.makeProfile(label: { "Key \($0)" })
    profile.assignments[0].action = .disabled; profile.assignments[1].action = .disabled
    mouse.failWrite = 2
    mouse.afterWrite = { device, _ in if device.writes.count == 3 { device.state.serial = "OTHER" } }
    #expect(throws: (any Error).self) { try ConfigurationWriter(io: mouse, repository: repo).apply(profile, expected: state) }
    #expect(mouse.writes.count == 3)
    #expect(try mouse.state.function(0x40) == .init(repeating: 0, count: 7))
    #expect(try mouse.state.function(0x41) == state.function(0x41))
    #expect(try repo.recovery(serial: state.serial)?.backup.hardware == state)
    #expect(try repo.saved(serial: state.serial) == nil)
}
