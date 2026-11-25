import Foundation
@testable import NagaCore
import Testing
@testable import Naga

@MainActor
private func connectionFixture(emit: @escaping (ButtonAction, Bool, Bool, pid_t?) -> Void) throws -> (AppModel, InputRouter, SavedProfile) {
    let router = InputRouter(startAutomatically: false, emit: emit)
    let model = AppModel(preview: true, router: router)
    var hardware = try #require(model.hardware)
    var profile = try hardware.makeProfile(label: { "Key \($0)" })
    let index = try #require(profile.assignments.firstIndex { $0.id == 0x49 })
    profile.assignments[index].action = .shortcut(Shortcut(keyCode: 123, modifiers: .control, keyLabel: "←"))
    hardware.bindings[index].function = [2, 2, 0, 0x40, 0, 0, 0]
    var app = ApplicationProfile(target: .bundleIdentifier("com.example.Game"), name: "Game")
    app.assignments = [Assignment(id: 0x49, action: .shortcut(Shortcut(keyCode: 38, keyLabel: "J")))]
    let saved = SavedProfile(profile: profile, hardware: hardware, routes: [], applicationProfiles: [app],
                             applicationTriggers: [ApplicationTrigger(control: 0x49, usage: 0x40)])
    try saved.validate()
    model.completeRefresh(.success((hardware, saved, false)), receiverPresent: true, silent: true)
    return (model, router, saved)
}

@MainActor @Test func normalWirelessSleepKeepsDefaultRoutesReadyWithoutAnErrorAlert() throws {
    var actions: [ButtonAction] = []
    let (model, router, saved) = try connectionFixture { action, down, _, _ in if down { actions.append(action) } }
    defer { model.shutdown() }
    #expect(model.connected)
    #expect(model.actionNeedsMac(0x49))
    model.completeRefresh(.failure(NagaError.status(3)), receiverPresent: true, silent: true)
    #expect(!model.connected)
    #expect(model.error == nil)
    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    router.receive(usage: 0x40, down: false, nanos: 1_100_000_000)
    #expect(actions == [saved.profile.assignments.first { $0.id == 0x49 }!.action])
}

@MainActor @Test func aUserRequestedReadStillShowsTheActualDeviceError() throws {
    let (model, _, _) = try connectionFixture { _, _, _, _ in }
    defer { model.shutdown() }
    model.completeRefresh(.failure(NagaError.status(3)), receiverPresent: true, silent: false)
    #expect(model.error == NagaError.status(3).localizedDescription)
}

@MainActor @Test func systemWakeRestartsDefaultRoutesAndPreservesUnappliedEdits() throws {
    var presses = 0
    let (model, router, saved) = try connectionFixture { _, down, _, _ in if down { presses += 1 } }
    defer { model.shutdown() }
    model.setAction(.disabled)
    let draft = model.profile
    #expect(model.dirty)
    model.handleSleep()
    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    #expect(presses == 0)
    model.handleWake()
    router.receive(usage: 0x40, down: true, nanos: 2_000_000_000)
    router.receive(usage: 0x40, down: false, nanos: 2_100_000_000)
    #expect(presses == 1)
    model.completeRefresh(.success((saved.hardware, saved, false)), receiverPresent: true, silent: true)
    #expect(model.profile == draft)
    #expect(model.dirty)
    #expect(model.error == nil)
}

@MainActor @Test func removingTheReceiverDisablesThePreviouslyVerifiedRoutes() throws {
    var presses = 0
    let (model, router, _) = try connectionFixture { _, down, _, _ in if down { presses += 1 } }
    defer { model.shutdown() }
    model.completeRefresh(.failure(NagaError.unavailable("Receiver disconnected")), receiverPresent: false, silent: true)
    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    #expect(presses == 0)
    #expect(model.error == nil)
}
