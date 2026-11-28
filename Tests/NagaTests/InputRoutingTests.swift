import AppKit
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

@Test func buttonTenSuppressesItsF7WhenTheTimestampsUseDifferentClocksAfterSleep() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit, clock: { (5_000_000_000, 65_000_000_000) })
    let shortcut = ButtonAction.shortcut(Shortcut(keyCode: 123, modifiers: .control, keyLabel: "←"))
    router.configure([0x40: shortcut], focusPID: 100)

    router.receive(usage: 0x40, down: true, nanos: 4_800_000_000)
    let keyboardF7 = try markerEvent(usage: 0x40, down: true, nanos: 64_900_000_000)
    #expect(router.filter(.keyDown, keyboardF7, waitForEdge: { _, _ in false }) != nil)
    let mouseF7Down = try markerEvent(usage: 0x40, down: true, nanos: 64_800_000_000)
    #expect(router.filter(.keyDown, mouseF7Down, waitForEdge: { _, _ in false }) == nil)

    router.receive(usage: 0x40, down: false, nanos: 64_850_000_000)
    let mouseF7Up = try markerEvent(usage: 0x40, down: false, nanos: 4_850_000_000)
    #expect(router.filter(.keyUp, mouseF7Up, waitForEdge: { _, _ in false }) == nil)
    #expect(deliveries.values.map(\.action) == [shortcut, shortcut])
    #expect(deliveries.values.map(\.down) == [true, false])
}

@Test func aLateMouseEdgeCanStillBeMatchedAtTheSessionTap() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    router.configure([0x40: .mouseButton(.button4)])
    let down = try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)
    #expect(router.filter(.keyDown, down, waitForEdge: { _, _ in false }) != nil)

    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    #expect(router.filter(.keyDown, down, waitForEdge: { _, _ in false }) == nil)
    #expect(deliveries.values.count == 1)
}

@Test func aVerifiedButtonTenPressSuppressesF7EvenWhenHIDDeliveryIsLate() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit, identifySender: { _ in true })
    let shortcut = ButtonAction.shortcut(Shortcut(keyCode: 123, modifiers: .control, keyLabel: "←"))
    router.configure([0x40: shortcut])

    let down = try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)
    let up = try markerEvent(usage: 0x40, down: false, nanos: 1_100_000_000)
    #expect(router.filter(.keyDown, down, waitForEdge: { _, _ in false }) == nil)
    #expect(router.filter(.keyUp, up, waitForEdge: { _, _ in false }) == nil)
    #expect(deliveries.values.map(\.down) == [true, false])

    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    router.receive(usage: 0x40, down: false, nanos: 1_100_000_000)
    #expect(deliveries.values.map(\.action) == [shortcut, shortcut])
    #expect(deliveries.values.map(\.down) == [true, false])
}

@Test func anIdentifiedKeyboardF7CannotConsumeACoincidentMousePress() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit, identifySender: { event in
        event.getIntegerValueField(.eventSourceUserData) == 1
    })
    router.configure([0x40: .mouseButton(.button4)])
    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)

    let keyboardDown = try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)
    #expect(router.filter(.keyDown, keyboardDown) != nil)

    let mouseDown = try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)
    mouseDown.setIntegerValueField(.eventSourceUserData, value: 1)
    #expect(router.filter(.keyDown, mouseDown, waitForEdge: { _, _ in
        Issue.record("The HID edge should still be available to its verified sender.")
        return false
    }) == nil)
    #expect(deliveries.values.map(\.down) == [true])
}

@Test func anOnboardControlArrowPassesOutsideItsApplicationProfile() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit, identifySender: { event in
        event.getIntegerValueField(.eventSourceUserData) == 1
    })
    let input = NativeInput.keyboard(0x50)
    let override = ButtonAction.shortcut(Shortcut(keyCode: 38, keyLabel: "J"))
    let down = try markerEvent(usage: 0x50, down: true, nanos: 1_000_000_000)
    down.flags = .maskControl
    down.setIntegerValueField(.eventSourceUserData, value: 1)
    let up = try markerEvent(usage: 0x50, down: false, nanos: 1_100_000_000)
    up.setIntegerValueField(.eventSourceUserData, value: 1)

    router.configure([:])
    #expect(router.filter(.keyDown, down) != nil)
    router.configure([:], native: [input: override], focusPID: 100)
    #expect(router.filter(.keyUp, up) != nil)
    router.receive(input: input, down: true, nanos: down.timestamp)
    #expect(deliveries.values.isEmpty)

    let physicalKeyboard = try markerEvent(usage: 0x50, down: true, nanos: down.timestamp)
    physicalKeyboard.flags = .maskControl
    #expect(router.filter(.keyDown, physicalKeyboard) != nil)
    #expect(router.filter(.keyDown, down) == nil)

    router.configure([:], focusPID: 200)
    #expect(router.filter(.keyUp, up) == nil)
    #expect(deliveries.values.map(\.action) == [override, override])
    #expect(deliveries.values.map(\.down) == [true, false])
    #expect(deliveries.values.last?.pid == 100)
    #expect(router.filter(.keyDown, down) != nil)
}

@Test func anOnboardMouseButtonCanUseRawInputToConfirmItsApplicationOverride() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit, identifySender: { _ in nil })
    let input = NativeInput.mouseButton(.button4)
    let override = ButtonAction.shortcut(Shortcut(keyCode: 38, keyLabel: "J"))
    router.configure([:], native: [input: override])
    let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
    down.setIntegerValueField(.mouseEventButtonNumber, value: 3)
    down.timestamp = 1_000_000_000
    #expect(router.filter(.otherMouseDown, down, waitForEdge: { _, _ in false }) != nil)
    router.receive(input: input, down: true, nanos: down.timestamp)
    #expect(deliveries.values.isEmpty)
    #expect(router.filter(.otherMouseDown, down) == nil)

    let up = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
    up.setIntegerValueField(.mouseEventButtonNumber, value: 3)
    up.timestamp = 1_100_000_000
    router.receive(input: input, down: false, nanos: up.timestamp)
    #expect(router.filter(.otherMouseUp, up) == nil)
    #expect(deliveries.values.map(\.down) == [true, false])
}

@Test func repeatedMissingHIDEventsRearmRoutingWithoutSwallowingUnmatchedKeys() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit, clock: { (10_000_000_000, 10_000_000_000) })
    router.configure([0x3f: .mouseButton(.button4), 0x40: .mouseButton(.button5)])
    router.receive(usage: 0x3f, down: true, nanos: 1_000_000_000)

    let first = try markerEvent(usage: 0x40, down: true, nanos: 2_000_000_000)
    #expect(router.filter(.keyDown, first, waitForEdge: { _, _ in false }) != nil)
    #expect(router.filter(.keyDown, first, waitForEdge: { _, _ in false }) != nil)
    #expect(deliveries.values.map(\.down) == [true])

    let second = try markerEvent(usage: 0x40, down: true, nanos: 2_500_000_000)
    #expect(router.filter(.keyDown, second, waitForEdge: { _, _ in false }) != nil)
    #expect(deliveries.values.map(\.down) == [true, false])

    router.receive(usage: 0x40, down: true, nanos: 3_000_000_000)
    let mousePress = try markerEvent(usage: 0x40, down: true, nanos: 3_000_000_000)
    #expect(router.filter(.keyDown, mousePress, waitForEdge: { _, _ in false }) == nil)
    router.receive(usage: 0x40, down: false, nanos: 3_100_000_000)
    #expect(deliveries.values.map(\.action) == [.mouseButton(.button4), .mouseButton(.button4), .mouseButton(.button5), .mouseButton(.button5)])
    #expect(deliveries.values.map(\.down) == [true, false, true, false])
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

@Test func aNewMousePressRecoversAfterAMissingHIDRelease() throws {
    let deliveries = Deliveries()
    let router = InputRouter(startAutomatically: false, emit: deliveries.emit)
    let action = ButtonAction.mouseButton(.button4)
    router.configure([0x40: action])

    router.receive(usage: 0x40, down: true, nanos: 1_000_000_000)
    let first = try markerEvent(usage: 0x40, down: true, nanos: 1_000_000_000)
    #expect(router.filter(.keyDown, first) == nil)

    router.receive(usage: 0x40, down: true, nanos: 2_000_000_000)
    let next = try markerEvent(usage: 0x40, down: true, nanos: 2_000_000_000)
    #expect(router.filter(.keyDown, next) == nil)
    router.receive(usage: 0x40, down: false, nanos: 2_100_000_000)

    #expect(deliveries.values.map(\.action) == [action, action, action, action])
    #expect(deliveries.values.map(\.down) == [true, false, true, false])
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
