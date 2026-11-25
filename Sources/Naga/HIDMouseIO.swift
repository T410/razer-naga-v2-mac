import Foundation
import Darwin
import IOKit
import IOKit.hid
import IOKit.hidsystem
import NagaCore

/// Uses the existing macOS HID stack, nonexclusively. No driver installation.
final class HIDMouseIO: MouseIO {
    private let device: IOHIDDevice
    private let loop: CFRunLoop
    private let mayWrite: Bool
    private var lock: Int32 = -1
    private var isOpen = false

    static var inputAccessStatus: InputAccessStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }
    static var hasInputAccess: Bool { inputAccessStatus == .granted }
    @discardableResult
    static func requestInputAccess() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    static var receiverPresent: Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x00b4] as CFDictionary)
        return !(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).isEmpty
    }

    init(directory: URL, mayWrite: Bool = false) throws {
        self.mayWrite = mayWrite
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x00b4,
            kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 2] as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let candidates = devices.filter {
            (IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) == "USB"
            && (IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? NSNumber)?.intValue == 90
        }
        guard candidates.count == 1, let device = candidates.first else {
            throw NagaError.unavailable(candidates.count > 1 ? "Connect only one Naga V2 HyperSpeed receiver." : "Waiting for a 2.4 GHz connection.")
        }
        self.device = device; self.loop = CFRunLoopGetCurrent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock = Darwin.open(directory.appendingPathComponent("device.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw NagaError.io("The device access lock could not be created.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); lock = -1
            throw NagaError.unavailable("Another Naga operation is in progress.")
        }
        let result = IOHIDDeviceOpen(device, 0)
        guard result == kIOReturnSuccess else {
            flock(lock, LOCK_UN); Darwin.close(lock); lock = -1
            throw Self.ioError(result)
        }
        isOpen = true
        IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
    }

    func execute(_ command: MouseCommand, allowWrites: Bool = false) throws -> [UInt8] {
        try command.validate(allowWrites: allowWrites && mayWrite)
        _ = try transfer(command.packet(), read: false)
        Thread.sleep(forTimeInterval: 0.035)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        repeat {
            let packet = try transfer(.init(repeating: 0, count: 90), read: true)
            if !command.shouldPoll(packet) { return try command.response(packet) }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NagaError.unavailable("The mouse response was incomplete. The command was not resent; wake the mouse and try again.")
    }

    private final class Completion {
        let buffer: UnsafeMutablePointer<UInt8>
        let size: UnsafeMutablePointer<CFIndex>
        var result: IOReturn?
        var received = 0
        init(bytes: [UInt8]) {
            buffer = .allocate(capacity: bytes.count); buffer.initialize(from: bytes, count: bytes.count)
            size = .allocate(capacity: 1); size.initialize(to: bytes.count)
        }
        deinit { buffer.deinitialize(count: 90); buffer.deallocate(); size.deinitialize(count: 1); size.deallocate() }
    }
    private func transfer(_ bytes: [UInt8], read: Bool) throws -> [UInt8] {
        guard isOpen, bytes.count == 90 else { throw NagaError.unavailable("The mouse connection is closed.") }
        let completion = Completion(bytes: bytes)
        // IOKit owns a retain until the callback, including a late callback after timeout.
        let opaque = Unmanaged.passRetained(completion).toOpaque()
        let callback: IOHIDReportCallback = { context, result, _, _, _, _, length in
            guard let context else { return }
            let value = Unmanaged<Completion>.fromOpaque(context).takeRetainedValue()
            value.received = length; value.result = result
        }
        let result: IOReturn
        if read {
            result = IOHIDDeviceGetReportWithCallback(device, kIOHIDReportTypeFeature, 0,
                completion.buffer, completion.size, 1000, callback, opaque)
        } else {
            result = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeFeature, 0,
                completion.buffer, 90, 1000, callback, opaque)
        }
        guard result == kIOReturnSuccess else { Unmanaged<Completion>.fromOpaque(opaque).release(); throw Self.ioError(result) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.25
        while completion.result == nil, ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        guard let finished = completion.result else {
            close()
            throw NagaError.unavailable("The USB operation timed out. Reconnect the receiver.")
        }
        guard finished == kIOReturnSuccess else { throw Self.ioError(finished) }
        guard !read || completion.received == 90 else { throw NagaError.protocolError("The USB response is not 90 bytes long.") }
        return Array(UnsafeBufferPointer(start: completion.buffer, count: 90))
    }
    private static func ioError(_ code: IOReturn) -> NagaError {
        .io("Could not access the mouse (\(String(format: "0x%08x", code))). Check Input Monitoring access and the USB connection.")
    }
    func close() {
        if isOpen {
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, 0); isOpen = false
        }
        if lock >= 0 { flock(lock, LOCK_UN); Darwin.close(lock); lock = -1 }
    }
    deinit { close() }
}
