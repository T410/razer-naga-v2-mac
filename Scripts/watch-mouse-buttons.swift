import Foundation
import IOKit.hid

// Read-only hardware diagnostic: only Mouse4/5 on this USB receiver. It never
// grabs the device, posts events, listens to keyboard keys, or sends reports.
final class MouseButtonObserver {
    struct Edge: Codable { let button: UInt32; let pressed: Bool; let uptime: Double }
    var edges: [Edge] = []
    var seen = Set<String>()
    func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let button = IOHIDElementGetUsage(element)
        guard IOHIDElementGetUsagePage(element) == 9, button == 4 || button == 5 else { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        edges.append(Edge(button: button, pressed: pressed, uptime: ProcessInfo.processInfo.systemUptime))
        seen.insert("\(button):\(pressed)")
        print("Mouse\(button) \(pressed ? "down" : "up")")
        fflush(stdout)
    }
}

let observer = MouseButtonObserver()
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x00b4,
    kIOHIDTransportKey: "USB", kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 2] as CFDictionary)
IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
    guard let context else { return }
    Unmanaged<MouseButtonObserver>.fromOpaque(context).takeUnretainedValue().receive(value)
}, Unmanaged.passUnretained(observer).toOpaque())
let loop = CFRunLoopGetCurrent()!
IOHIDManagerScheduleWithRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
let opened = IOHIDManagerOpen(manager, 0)
guard opened == kIOReturnSuccess else {
    fputs("Read-only monitor could not open the receiver: \(opened). Check Input Monitoring permission.\n", stderr)
    exit(1)
}
defer {
    IOHIDManagerUnscheduleFromRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerClose(manager, 0)
}
print("READY: tilt left and right once each; only Naga Mouse4/5 press/release events are observed (60 seconds).")
fflush(stdout)
let deadline = ProcessInfo.processInfo.systemUptime + 60
while observer.seen.count < 4, ProcessInfo.processInfo.systemUptime < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.05, false)
}
if let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.indices.contains(index + 1) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(observer.edges).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
}
guard observer.seen == Set(["4:true", "4:false", "5:true", "5:false"]) else {
    fputs("Timed out before observing both Mouse4 and Mouse5 press/release pairs. No settings written.\n", stderr)
    exit(1)
}
print("PASS: native Mouse4 and Mouse5 press/release pairs observed. No settings written.")
