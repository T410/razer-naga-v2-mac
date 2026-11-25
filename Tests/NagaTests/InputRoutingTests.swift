import AppKit
import Carbon
import NagaCore
import Testing
@testable import Naga

private final class Deliveries: @unchecked Sendable {
    struct Entry: Equatable {
        var action: ButtonAction
        var down: Bool
        var repeatKey: Bool
        var pid: pid_t?
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    var values: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func emit(_ action: ButtonAction, _ down: Bool, _ repeatKey: Bool, _ pid: pid_t?) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(action: action, down: down, repeatKey: repeatKey, pid: pid))
    }
}

private func markerEvent(usage: UInt8, down: Bool, nanos: UInt64) throws -> CGEvent {
    let code = try #require(HIDKeys.keyCode(for: usage))
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
    event.timestamp = nanos
    return event
}

@Test func mouseEdgesRunAllThreeDefaultControlArrowsWithoutKeyboardCallbacks() {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    let actions = [123, 126, 124].map { ButtonAction.shortcut(Shortcut(keyCode: UInt16($0), modifiers: .control, keyLabel: "Arrow")) }
    let usages: [UInt8] = [0x40, 0x3f, 0x3e]
    router.configure(Dictionary(uniqueKeysWithValues: zip(usages, actions)), focusPID: 100)
    for usage in usages {
        router.receive(usage: usage, down: true, nanos: 1_000_000_000)
        router.receive(usage: usage, down: false, nanos: 1_100_000_000)
    }
    #expect(deliveries.values.map(\.action) == actions.flatMap { [$0, $0] })
    #expect(deliveries.values.map(\.down) == [true, false, true, false, true, false])
}

@Test func aKeyboardEventArrivingBeforeTheMouseCallbackIsStillSuppressedExactlyOnce() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    router.configure([0x40: .mouseButton(.button4)])
    let down = try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)
    var waits = 0
    let filtered = router.filter(.keyDown, down, waitForEdge: { condition, _ in
        waits += 1
        // Deliver the mouse callback only after the keyboard event starts waiting,
        // releasing the condition just as NSCondition.wait does in production.
        condition.unlock()
        defer { condition.lock() }
        router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
        return true
    })
    #expect(waits == 1)
    #expect(filtered == nil)
    #expect(deliveries.values.count == 1)
    #expect(router.filter(.keyDown, down, waitForEdge: { _, _ in false }) != nil)
    #expect(deliveries.values.count == 1)
    router.receive(usage: 0x40, down: false, nanos: 1_100_000_000)
    #expect(router.filter(.keyUp, try markerEvent(usage: 0x40, down: false, nanos: 1_100_000_000)) == nil)
    #expect(deliveries.values.map(\.down) == [true, false])
}

@Test func physicalKeyboardFunctionKeysPassThroughWithoutRunningMouseActions() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    router.configure([0x40: .mouseButton(.button5)])
    #expect(router.filter(.keyDown, try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)) != nil)
    #expect(router.filter(.keyUp, try markerEvent(usage: 0x40, down: false, nanos: 1_100_000_000)) != nil)
    #expect(deliveries.values.isEmpty)
}

@Test func focusChangesReleaseTheOldActionAndRequireANewMousePress() {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    router.configure([0x40: .mouseButton(.button4)], focusPID: 100)
    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    router.configure([0x40: .mouseButton(.button5)], focusPID: 200)
    router.receive(usage: 0x40, down: true, nanos: 1_010_000_000)
    router.receive(usage: 0x40, down: false, nanos: 1_020_000_000)
    #expect(deliveries.values.count == 2)
    #expect(deliveries.values[1].down == false)
    #expect(deliveries.values[1].pid == 100)
    router.receive(usage: 0x40, down: true, nanos: 1_100_000_000)
    #expect(deliveries.values.last?.action == .mouseButton(.button5))
    #expect(deliveries.values.last?.down == true)
}

@Test func wakingReleasesHeldActionsAndKeepsTheDefaultRoutesReady() {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    router.configure([0x40: .mouseButton(.button4)])
    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    router.restart()
    router.receive(usage: 0x40, down: true, nanos: 2_000_000_000)
    router.receive(usage: 0x40, down: false, nanos: 2_100_000_000)
    #expect(deliveries.values.map(\.down) == [true, false, true, false])
}

@Test func loginLaunchesStayInTheBackgroundAndManualLaunchesOpenTheWindow() {
    #expect(!LoginItem.isBackgroundLaunch(arguments: ["Naga"], event: nil))
    #expect(LoginItem.isBackgroundLaunch(arguments: ["Naga", "--background"], event: nil))
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    #expect(LoginItem.isBackgroundLaunch(arguments: ["Naga"], event: event))
}
