import AppKit
import IOKit.hid
import NagaCore

/// Only the Naga's reserved software triggers are observed. The physical keyboard
/// is never enumerated. A matching device edge is required before filtering.
final class InputRouter: @unchecked Sendable {
    private struct Edge { let usage: UInt8; let down: Bool; let nanos: UInt64 }
    private struct Held {
        let action: ButtonAction
        var released = false
    }
    private let lock = NSCondition()
    private let inputQueue = DispatchQueue(label: "Naga.input.hid", qos: .userInteractive)
    private let startAutomatically: Bool
    private let emit: ((ButtonAction, Bool, Bool, pid_t?) -> Void)?
    private var routes: [UInt8: ButtonAction] = [:]
    private var focusPID: pid_t?
    private var edges: [Edge] = []
    private var held: [UInt8: Held] = [:]
    private var loop: CFRunLoop?
    private var manager: IOHIDManager?
    private var tap: CFMachPort?
    private var thread: Thread?
    private var stopping = false
    private var restarting = false
    private let eventTag: Int64 = 0x4e414741
    private var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    init(startAutomatically: Bool = true, emit: ((ButtonAction, Bool, Bool, pid_t?) -> Void)? = nil) {
        self.startAutomatically = startAutomatically
        self.emit = emit
    }

    func configure(_ routes: [UInt8: ButtonAction], focusPID: pid_t? = nil) {
        lock.lock()
        let changedApp = self.focusPID != focusPID
        for (usage, press) in held where !press.released && (changedApp || self.routes[usage] != routes[usage]) {
            send(press.action, down: false, to: changedApp ? self.focusPID : nil)
            // The physical trigger may remain held across a focus change. Consume
            // its repeats and final release without starting the new action.
            held[usage]?.released = true
        }
        self.routes = routes
        self.focusPID = focusPID
        var worker: Thread?
        if startAutomatically, !routes.isEmpty, thread == nil, AXIsProcessTrusted(), HIDMouseIO.hasInputAccess {
            worker = Thread { [weak self] in self?.run() }
            worker?.name = "Naga input"; thread = worker
        }
        lock.unlock()
        worker?.start()
    }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return tap != nil }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return thread != nil }
    func stop() {
        configure([:])
        lock.lock(); stopping = true; restarting = false; let loop = self.loop; lock.unlock()
        if let loop { CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }; CFRunLoopWakeUp(loop) }
    }
    func restart() {
        releaseAll()
        lock.lock()
        let loop = self.loop
        let hasThread = thread != nil
        restarting = hasThread
        stopping = hasThread
        let routes = self.routes, pid = focusPID
        lock.unlock()
        if let loop { CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }; CFRunLoopWakeUp(loop) }
        else if !hasThread { configure(routes, focusPID: pid) }
    }
    private func run() {
        let loop = CFRunLoopGetCurrent()!
        lock.lock(); self.loop = loop; let shouldStop = stopping; lock.unlock()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        if shouldStop { clean(manager: manager, loop: loop); return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x00b4] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<InputRouter>.fromOpaque(context).takeUnretainedValue().input(value)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }; Unmanaged<InputRouter>.fromOpaque(context).takeUnretainedValue().releaseAll()
        }, context)
        // HID delivery must remain live while the event tap waits for a matching
        // mouse edge. Sharing their run loop made callback order significant.
        IOHIDManagerSetDispatchQueue(manager, inputQueue)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { clean(manager: manager, loop: loop); return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<InputRouter>.fromOpaque(context).takeUnretainedValue().filter(type, event)
            }, userInfo: context) else { clean(manager: manager, loop: loop); return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lock.lock(); self.manager = manager; self.loop = loop; self.tap = tap; lock.unlock()
        CFRunLoopAddSource(loop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        IOHIDManagerActivate(manager)
        CFRunLoopRun()
        releaseAll(); CFMachPortInvalidate(tap); CFRunLoopRemoveSource(loop, source, .defaultMode)
        clean(manager: manager, loop: loop, activated: true)
    }
    private func clean(manager: IOHIDManager, loop: CFRunLoop, activated: Bool = false) {
        if activated {
            IOHIDManagerCancel(manager)
            // Drain callbacks before replacing the manager on wake.
            inputQueue.sync {}
        }
        IOHIDManagerClose(manager, 0)
        lock.lock()
        self.tap = nil; self.manager = nil; self.loop = nil; self.thread = nil
        let restart = restarting, routes = self.routes, pid = focusPID
        restarting = false; stopping = false
        lock.unlock()
        if restart { configure(routes, focusPID: pid) }
    }
    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == 7, IOHIDElementGetUsage(element) <= 255 else { return }
        let usage = UInt8(IOHIDElementGetUsage(element)), down = IOHIDValueGetIntegerValue(value) != 0
        let ticks = IOHIDValueGetTimeStamp(value)
        let nanos = UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
        receive(usage: usage, down: down, nanos: nanos)
    }
    // The mouse edge is authoritative even if macOS consumes a function key or
    // delivers its keyboard event first. The event tap only suppresses markers.
    func receive(usage: UInt8, down: Bool, nanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !stopping else { return }
        guard routes[usage] != nil || held[usage] != nil else { return }
        edges.append(Edge(usage: usage, down: down, nanos: nanos))
        if edges.count > 128 { edges.removeFirst(edges.count - 128) }
        if down, held[usage] == nil, let action = routes[usage] {
            held[usage] = Held(action: action)
            send(action, down: true)
        } else if !down, let press = held.removeValue(forKey: usage), !press.released {
            send(press.action, down: false)
        }
        lock.broadcast()
    }
    func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseAll()
            lock.lock(); let tap = self.tap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != eventTag,
              let usage = HIDKeys.usage(for: UInt16(event.getIntegerValueField(.keyboardEventKeycode))) else { return Unmanaged.passUnretained(event) }
        let down = type == .keyDown
        lock.lock()
        defer { lock.unlock() }
        if down, event.getIntegerValueField(.keyboardEventAutorepeat) != 0, let press = held[usage] {
            if !press.released, case .shortcut = press.action { send(press.action, down: true, repeatKey: true) }
            return nil
        }
        guard routes[usage] != nil || held[usage] != nil || edges.contains(where: { $0.usage == usage }) else { return Unmanaged.passUnretained(event) }
        let deadline = Date(timeIntervalSinceNow: 0.025)
        func matchingEdge() -> Int? {
            edges.firstIndex { $0.usage == usage && $0.down == down && abs(Double($0.nanos) - Double(event.timestamp)) <= 50_000_000 }
        }
        // The HID callback runs on inputQueue and signals this condition. A
        // physical keyboard's unmatched function key always passes through.
        while matchingEdge() == nil, !stopping {
            if !lock.wait(until: deadline) { break }
        }
        guard let index = matchingEdge() else { return Unmanaged.passUnretained(event) }
        edges.remove(at: index)
        return nil
    }
    private func send(_ action: ButtonAction, down: Bool, repeatKey: Bool = false, to pid: pid_t? = nil) {
        if let emit { emit(action, down, repeatKey, pid); return }
        let event: CGEvent
        let location: CGEventTapLocation
        switch action {
        case .shortcut(let shortcut):
            let source = CGEventSource(stateID: .hidSystemState)
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down) else { return }
            key.flags = KeyLabels.eventFlags(for: shortcut)
            if repeatKey { key.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event = key
            // System shortcuts such as Mission Control need to see the chord at HID entry.
            location = .cghidEventTap
        case .mouseButton(let button):
            guard let cursor = CGEvent(source: nil)?.location,
                  let click = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState),
                                      mouseType: down ? .otherMouseDown : .otherMouseUp,
                                      mouseCursorPosition: cursor, mouseButton: .center) else { return }
            click.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue - 1))
            click.setIntegerValueField(.mouseEventClickState, value: 1)
            event = click
            location = .cgSessionEventTap
        case .disabled, .original:
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        if let pid { event.postToPid(pid) }
        else { event.post(tap: location) }
    }

    private func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for press in held.values where !press.released { send(press.action, down: false, to: focusPID) }
        held.removeAll(); edges.removeAll()
    }
}
