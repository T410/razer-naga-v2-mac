import AppKit
import Combine
import IOKit.hidsystem
import NagaCore

enum InputAccessStatus: Equatable {
    case unknown, denied, granted
}

enum PrivacyPermission: String, CaseIterable {
    case inputMonitoring, accessibility

    var title: String { self == .inputMonitoring ? "Input Monitoring" : "Accessibility" }
    var service: String { self == .inputMonitoring ? "ListenEvent" : "Accessibility" }
    var resetArguments: [String] { ["reset", service, AppIdentity.bundleIdentifier] }
    var settingsURL: URL {
        let pane = self == .inputMonitoring ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Requests are kept separate from opening Settings: macOS owns the approval
/// prompt and its Settings button. Merely opening the pane cannot register us.
@MainActor
final class PermissionSetup: ObservableObject {
    enum Continuation: Equatable {
        case complete, requested
        case renew(PrivacyPermission)
    }

    struct Client {
        var inputStatus: () -> InputAccessStatus
        var requestInput: () -> Bool
        var accessibilityGranted: () -> Bool
        var requestAccessibility: () -> Bool
        var openSettings: (PrivacyPermission) -> Void
        var reset: (PrivacyPermission) async throws -> Void

        static var live: Self {
            Self(inputStatus: { HIDMouseIO.inputAccessStatus },
                 requestInput: { HIDMouseIO.requestInputAccess() },
                 accessibilityGranted: { AXIsProcessTrusted() },
                 requestAccessibility: {
                     AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                 },
                 openSettings: { NSWorkspace.shared.open($0.settingsURL) },
                 reset: { permission in
                     let arguments = permission.resetArguments
                     try await Task.detached(priority: .userInitiated) {
                         let process = Process()
                         let output = Pipe()
                         process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                         process.arguments = arguments
                         process.standardOutput = output
                         process.standardError = output
                         try process.run()
                         let data = output.fileHandleForReading.readDataToEndOfFile()
                         process.waitUntilExit()
                         guard process.terminationStatus == 0 else {
                             let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                             throw NagaError.unavailable("The permission request could not be renewed. \(detail)")
                         }
                     }.value
                 })
        }
    }

    @Published private(set) var inputStatus: InputAccessStatus = .unknown
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var requested: Set<PrivacyPermission> = []
    private let client: Client
    private let isInteractive: () -> Bool
    private var started = false
    private var requesting = false
    private var needsAccessibility = true

    var nextPermission: PrivacyPermission? {
        if needsAccessibility, !accessibilityGranted { return .accessibility }
        return inputStatus == .granted ? nil : .inputMonitoring
    }

    init(client: Client? = nil, isInteractive: (() -> Bool)? = nil) {
        self.client = client ?? .live
        self.isInteractive = isInteractive ?? { NSApp.isActive }
    }

    func begin(needsAccessibility: Bool) {
        started = true
        refresh(needsAccessibility: needsAccessibility)
    }

    func refresh(needsAccessibility: Bool) {
        self.needsAccessibility = needsAccessibility
        readStatus()
        guard started, isInteractive(), !requesting else { return }
        // Event-control access can also satisfy listening access. Ask for it
        // first instead of letting a failed listening request block every step.
        if let permission = nextPermission, !requested.contains(permission) { request(permission) }
    }

    /// A single explicit action continues the same sequence as startup. Read
    /// status without auto-requesting first, so a new request cannot immediately
    /// be mistaken for a failed previous request and reset in the same click.
    func continueSetup(needsAccessibility: Bool) -> Continuation {
        self.needsAccessibility = needsAccessibility
        started = true
        readStatus()
        guard let permission = nextPermission else { return .complete }
        guard !requested.contains(permission) else { return .renew(permission) }
        request(permission)
        return .requested
    }

    func request(_ permission: PrivacyPermission) {
        guard !requesting else { return }
        started = true
        if permission == .inputMonitoring, client.inputStatus() == .granted { return }
        if permission == .accessibility, client.accessibilityGranted() { return }
        requesting = true
        requested.insert(permission)
        switch permission {
        case .inputMonitoring: _ = client.requestInput()
        case .accessibility: _ = client.requestAccessibility()
        }
        readStatus()
        requesting = false
    }

    private func readStatus() {
        inputStatus = client.inputStatus()
        accessibilityGranted = client.accessibilityGranted()
    }

    func openSettings(_ permission: PrivacyPermission) { client.openSettings(permission) }

    /// Called only after an explicit confirmation to renew this app's own
    /// previous decision. A relaunch drops the per-process HID/TCC cache.
    func reset(_ permission: PrivacyPermission) async throws { try await client.reset(permission) }
}
