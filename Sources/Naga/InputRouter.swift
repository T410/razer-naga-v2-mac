import AppKit
import IOKit.hid
import NagaCore
import os

/// A matching Naga HID edge or a verified sender is required to route input.
final class InputRouter: @unchecked Sendable {
    private enum EdgeSource { case hid, quartz }
    private struct Edge {
        let input: NativeInput
        let down: Bool
        let nanos: UInt64
        let source: EdgeSource
        let isMarker: Bool
    }
    private struct Route: Equatable {
        let action: ButtonAction
        let isMarker: Bool
    }
    private struct Held {
        let route: Route
        let startNanos: UInt64
        var matchedKeyDown = false
        var released = false
    }
    private let lock = NSCondition()
    private let inputQueue = DispatchQueue(label: "Naga.input.hid", qos: .userInteractive)
    private let outputQueue = DispatchQueue(label: "Naga.input.output", qos: .userInteractive)
    private let startAutomatically: Bool
    private let emit: ((ButtonAction, Bool, Bool, pid_t?) -> Void)?
    private let clock: () -> (uptime: UInt64, continuous: UInt64)
    private let identifySender: ((CGEvent) -> Bool?)?
    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "Input")
    // Quartz carries the IORegistry sender ID here on supported systems. Keep
    // HID correlation as the fallback when this undocumented field is absent.
    private static let senderIDField = CGEventField(rawValue: 87)
    private var routes: [NativeInput: Route] = [:]
    private var focusPID: pid_t?
    private var edges: [Edge] = []
    private var held: [NativeInput: Held] = [:]
    private var receiverSenders: [UInt64: Bool] = [:]
    private var loop: CFRunLoop?
    private var taps: [CFMachPort] = []
    private var thread: Thread?
    private var stopping = false
    private var restarting = false
    private var lastUnmatchedDown: UInt64?
    private var lastUnmatchedRecovery: UInt64?
    private let eventTag: Int64 = 0x4e414741
    private var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    init(startAutomatically: Bool = true, emit: ((ButtonAction, Bool, Bool, pid_t?) -> Void)? = nil,
         clock: @escaping () -> (uptime: UInt64, continuous: UInt64) = {
             (clock_gettime_nsec_np(CLOCK_UPTIME_RAW), clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
         }, identifySender: ((CGEvent) -> Bool?)? = nil) {
        self.startAutomatically = startAutomatically
        self.emit = emit
        self.clock = clock
        self.identifySender = identifySender
    }

    func configure(_ markers: [UInt8: ButtonAction], native: [NativeInput: ButtonAction] = [:], focusPID: pid_t? = nil) {
        var routes = native.mapValues { Route(action: $0, isMarker: false) }
        for (usage, action) in markers { routes[.keyboard(usage)] = Route(action: action, isMarker: true) }
        lock.lock()
        let changedApp = self.focusPID != focusPID
        for (input, press) in held where !press.released && (changedApp || self.routes[input] != routes[input]) {
            send(press.route.action, down: false, to: changedApp ? self.focusPID : nil)
            // The physical trigger may remain held across a focus change. Consume
            // its repeats and final release without starting the new action.
            held[input]?.released = true
        }
        self.routes = routes
        self.focusPID = focusPID
        let worker = makeWorkerIfNeeded()
        lock.unlock()
        worker?.start()
    }

    // Called with the condition locked so only one listener owns the current routes.
    private func makeWorkerIfNeeded() -> Thread? {
        guard startAutomatically, !routes.isEmpty, !stopping, thread == nil,
              AXIsProcessTrusted(), HIDMouseIO.hasInputAccess else { return nil }
        let worker = Thread { [weak self] in self?.run() }
        worker.name = "Naga input"
        thread = worker
        return worker
    }

    var ready: Bool { lock.lock(); defer { lock.unlock() }; return !stopping && !taps.isEmpty }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return thread != nil }
    func stop() {
        configure([:])
        lock.lock()
        stopWorker(restart: false)
        lock.unlock()
        outputQueue.sync {}
    }
    func restart() {
        lock.lock()
        if !stopping { restartLocked(reason: "requested") }
        let worker = makeWorkerIfNeeded()
        lock.unlock()
        worker?.start()
    }

    private func stopWorker(restart: Bool) {
        stopping = thread != nil
        restarting = stopping && restart
        lock.broadcast()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
    }

    private func restartLocked(reason: String) {
        if thread != nil { logger.notice("Rebuilding the input listener: \(reason, privacy: .public)") }
        releaseAllLocked()
        stopWorker(restart: true)
    }

    private func run() {
        defer { workerDidExit() }
        let loop = CFRunLoopGetCurrent()!
        lock.lock(); self.loop = loop; let shouldStop = stopping; lock.unlock()
        guard !shouldStop else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x00b4,
                                               kIOHIDTransportKey: "USB"] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: 7],
            [kIOHIDElementUsagePageKey: 9, kIOHIDElementUsageKey: 4],
            [kIOHIDElementUsagePageKey: 9, kIOHIDElementUsageKey: 5]
        ] as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context else { return }
            let router = Unmanaged<InputRouter>.fromOpaque(context).takeUnretainedValue()
            if result == kIOReturnSuccess { router.input(value) }
            else { router.recoverListener(reason: "HID input error") }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<InputRouter>.fromOpaque(context).takeUnretainedValue().recoverListener(reason: "USB interface removed")
        }, context)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { return }
        defer { IOHIDManagerClose(manager, 0) }
        let types: [CGEventType] = [.keyDown, .keyUp, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // Filter at HID entry when available, and again as events enter the
        // login session so a marker missed by the first tap can still be caught.
        let locations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]
        let taps = locations.compactMap { location in
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<InputRouter>.fromOpaque(context).takeUnretainedValue().filter(type, event)
                }, userInfo: context)
        }
        guard !taps.isEmpty else { return }
        lock.lock(); self.taps = taps; lock.unlock()
        let sources = taps.map { tap in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(loop, source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            return source
        }
        let watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkTaps(taps) }
        RunLoop.current.add(watchdog, forMode: .default)
        // HID delivery stays live while the event tap waits for a matching edge.
        let canceled = DispatchSemaphore(value: 0)
        IOHIDManagerSetDispatchQueue(manager, inputQueue)
        IOHIDManagerSetCancelHandler(manager) { canceled.signal() }
        IOHIDManagerActivate(manager)
        CFRunLoopRun()
        watchdog.invalidate()
        lock.lock()
        stopping = true
        releaseAllLocked()
        lock.unlock()
        for (tap, source) in zip(taps, sources) {
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(loop, source, .defaultMode)
        }
        IOHIDManagerCancel(manager)
        // IOKit may still have callbacks in flight after cancellation is requested.
        canceled.wait()
    }

    private func workerDidExit() {
        lock.lock()
        taps.removeAll(); loop = nil; thread = nil
        receiverSenders.removeAll(keepingCapacity: true)
        let restart = restarting
        restarting = false; stopping = false
        let worker = restart ? makeWorkerIfNeeded() : nil
        lock.unlock()
        worker?.start()
    }

    private func checkTaps(_ taps: [CFMachPort]) {
        lock.lock()
        let shouldCheck = !stopping && !routes.isEmpty
        lock.unlock()
        guard shouldCheck else { return }
        var hasEnabledTap = false
        for tap in taps where CFMachPortIsValid(tap) {
            if CGEvent.tapIsEnabled(tap: tap) {
                hasEnabledTap = true
            } else {
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { hasEnabledTap = true }
            }
        }
        if !hasEnabledTap { recoverListener(reason: "no usable event tap") }
    }

    private func recoverListener(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard !stopping, !routes.isEmpty else { return }
        restartLocked(reason: reason)
    }
    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard let usage = UInt8(exactly: IOHIDElementGetUsage(element)) else { return }
        let input: NativeInput
        switch IOHIDElementGetUsagePage(element) {
        case 7: input = .keyboard(usage)
        case 9:
            guard let button = MouseButtonAction(rawValue: usage) else { return }
            input = .mouseButton(button)
        default: return
        }
        let ticks = IOHIDValueGetTimeStamp(value)
        let nanos = UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
        receive(input: input, down: IOHIDValueGetIntegerValue(value) != 0, nanos: nanos)
    }

    func receive(usage: UInt8, down: Bool, nanos: UInt64) {
        receive(input: .keyboard(usage), down: down, nanos: nanos)
    }

    func receive(input: NativeInput, down: Bool, nanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !stopping, let route = held[input]?.route ?? routes[input] else { return }
        lastUnmatchedDown = nil
        let timestamp = uptimeTimestamp(nanos)
        if route.isMarker, let index = matchingEdge(input: input, down: down, nanos: timestamp, source: .quartz, isMarker: true) {
            edges.remove(at: index)
            return
        }
        recordEdge(input: input, down: down, nanos: timestamp, source: .hid, isMarker: route.isMarker)
        // Native actions begin only when Quartz can suppress the original. A
        // raw release can still balance an override if Quartz missed its up.
        if route.isMarker {
            applyEdge(input: input, down: down, nanos: timestamp)
        } else if !down, let press = held[input], !press.released {
            send(press.route.action, down: false)
            held[input]?.released = true
        }
        lock.broadcast()
    }

    private func applyEdge(input: NativeInput, down: Bool, nanos: UInt64, matchedKeyDown: Bool = false) {
        if down {
            guard let route = routes[input] else { return }
            if let press = held[input] {
                // Two distinct confirmed key-downs mean the previous release was missed.
                guard matchedKeyDown, press.matchedKeyDown, nanos > press.startNanos,
                      nanos - press.startNanos > 50_000_000 else { return }
                if !press.released { send(press.route.action, down: false) }
            }
            held[input] = Held(route: route, startNanos: nanos, matchedKeyDown: matchedKeyDown)
            send(route.action, down: true)
        } else if let press = held.removeValue(forKey: input), !press.released {
            send(press.route.action, down: false)
        }
    }

    private func recordEdge(input: NativeInput, down: Bool, nanos: UInt64, source: EdgeSource, isMarker: Bool) {
        edges.append(Edge(input: input, down: down, nanos: nanos, source: source, isMarker: isMarker))
        if edges.count > 128 { edges.removeFirst(edges.count - 128) }
    }

    private func matchingEdge(input: NativeInput, down: Bool, nanos: UInt64, source: EdgeSource, isMarker: Bool) -> Int? {
        edges.firstIndex { $0.input == input && $0.down == down && $0.source == source && $0.isMarker == isMarker
            && abs(Double($0.nanos) - Double(nanos)) <= 50_000_000 }
    }

    private func isReceiverSender(_ event: CGEvent) -> Bool? {
        if let identifySender { return identifySender(event) }
        guard let field = Self.senderIDField else { return nil }
        let id = UInt64(bitPattern: event.getIntegerValueField(field))
        guard id != 0 else { return nil }
        if let cached = receiverSenders[id] { return cached }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let vendor = property(kIOHIDVendorIDKey) as? NSNumber,
              let product = property(kIOHIDProductIDKey) as? NSNumber else { return nil }
        var isReceiver = false
        if vendor.intValue == 0x1532, product.intValue == 0x00b4 {
            guard let transport = property(kIOHIDTransportKey) as? String else { return nil }
            isReceiver = transport == "USB"
        }
        if receiverSenders.count >= 32 { receiverSenders.removeAll(keepingCapacity: true) }
        receiverSenders[id] = isReceiver
        if isReceiver { logger.notice("Verified the receiver as the sender of a Quartz trigger") }
        return isReceiver
    }

    func filter(_ type: CGEventType, _ event: CGEvent,
                waitForEdge: (NSCondition, Date) -> Bool = { $0.wait(until: $1) }) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let taps = self.taps; lock.unlock()
            for tap in taps where CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != eventTag else { return Unmanaged.passUnretained(event) }
        let input: NativeInput
        switch type {
        case .keyDown, .keyUp:
            guard let code = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)),
                  let usage = HIDKeys.usage(for: code) else { return Unmanaged.passUnretained(event) }
            input = .keyboard(usage)
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            guard let number = UInt8(exactly: event.getIntegerValueField(.mouseEventButtonNumber)),
                  number == 3 || number == 4, let button = MouseButtonAction(rawValue: number + 1) else {
                return Unmanaged.passUnretained(event)
            }
            input = .mouseButton(button)
        default: return Unmanaged.passUnretained(event)
        }
        let down = type == .keyDown || type == .otherMouseDown
        lock.lock()
        defer { lock.unlock() }
        let route = held[input]?.route ?? routes[input]
        let isMarker = route?.isMarker ?? edges.contains { $0.input == input && $0.isMarker }
        guard route != nil || isMarker else { return Unmanaged.passUnretained(event) }
        let fromReceiver = isReceiverSender(event)
        if fromReceiver == false { return Unmanaged.passUnretained(event) }
        guard !stopping else { return isMarker && fromReceiver == true ? nil : Unmanaged.passUnretained(event) }
        if type == .otherMouseDragged {
            if held[input] != nil, fromReceiver == true { event.type = .mouseMoved }
            return Unmanaged.passUnretained(event)
        }
        if !isMarker, !down, held[input] == nil { return Unmanaged.passUnretained(event) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            if let press = held[input], isMarker || fromReceiver == true {
                if !press.released, case .shortcut = press.route.action { send(press.route.action, down: true, repeatKey: true) }
                return nil
            }
            return isMarker && fromReceiver == true ? nil : Unmanaged.passUnretained(event)
        }
        let nanos = uptimeTimestamp(event.timestamp)
        let deadline = Date(timeIntervalSinceNow: 0.025)
        func hidEdge() -> Int? {
            matchingEdge(input: input, down: down, nanos: nanos, source: .hid, isMarker: isMarker)
        }
        // The HID callback runs on inputQueue and signals this condition. A
        // physical keyboard's unmatched function key always passes through.
        while (isMarker || fromReceiver == nil), hidEdge() == nil, !stopping {
            if !waitForEdge(lock, deadline) { break }
        }
        if !isMarker {
            guard !stopping, fromReceiver == true || hidEdge() != nil else { return Unmanaged.passUnretained(event) }
            if let index = hidEdge() { edges.remove(at: index) }
            let wasHeld = held[input] != nil
            applyEdge(input: input, down: down, nanos: nanos, matchedKeyDown: true)
            return (down ? held[input] != nil : wasHeld) ? nil : Unmanaged.passUnretained(event)
        }
        guard let index = hidEdge() else {
            if fromReceiver == true {
                if !stopping {
                    recordEdge(input: input, down: down, nanos: nanos, source: .quartz, isMarker: true)
                    applyEdge(input: input, down: down, nanos: nanos, matchedKeyDown: true)
                }
                return nil
            }
            if !stopping, down, routes[input] != nil {
                noteUnmatchedDown(nanos)
            }
            return Unmanaged.passUnretained(event)
        }
        let edge = edges.remove(at: index)
        if down, let press = held[input] {
            if press.startNanos == edge.nanos {
                held[input]?.matchedKeyDown = true
            } else {
                applyEdge(input: input, down: true, nanos: edge.nanos, matchedKeyDown: true)
            }
        }
        return nil
    }

    private func noteUnmatchedDown(_ nanos: UInt64) {
        // Both event taps may see the same press. Only distinct presses count.
        guard nanos > 0, lastUnmatchedDown != nanos else { return }
        let previous = lastUnmatchedDown
        lastUnmatchedDown = nanos
        guard let previous, nanos > previous, nanos - previous <= 3_000_000_000 else { return }
        if let lastUnmatchedRecovery, nanos >= lastUnmatchedRecovery, nanos - lastUnmatchedRecovery < 5_000_000_000 { return }
        // Quartz cannot distinguish an unmatched marker from a keyboard press.
        // Pass it through and rearm the HID listener for the next press.
        lastUnmatchedRecovery = nanos
        restartLocked(reason: "repeated markers without HID input")
    }

    // There can be a large offset after system sleep between timestamps that
    // include sleep and timestamps that count only time awake. Normalize recent
    // samples before matching the two input streams.
    private func uptimeTimestamp(_ nanos: UInt64) -> UInt64 {
        let (uptime, continuous) = clock()
        guard continuous > uptime else { return nanos }
        let sleep = continuous - uptime
        guard nanos >= sleep, nanos > uptime, nanos - uptime > sleep / 2 else { return nanos }
        return nanos - sleep
    }

    private func send(_ action: ButtonAction, down: Bool, repeatKey: Bool = false, to pid: pid_t? = nil) {
        if let emit { emit(action, down, repeatKey, pid); return }
        // Posting can call into WindowServer while its event tap waits on us.
        // Keep those calls off both the HID queue and the correlation lock.
        outputQueue.async { self.post(action, down: down, repeatKey: repeatKey, to: pid) }
    }

    private func post(_ action: ButtonAction, down: Bool, repeatKey: Bool, to pid: pid_t?) {
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

    private func releaseAllLocked() {
        for press in held.values where !press.released { send(press.route.action, down: false, to: focusPID) }
        held.removeAll(); edges.removeAll()
        lastUnmatchedDown = nil
    }
}
