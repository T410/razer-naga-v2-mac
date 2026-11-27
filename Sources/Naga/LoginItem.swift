import AppKit
import Carbon
import ServiceManagement
import NagaCore

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func configureOnFirstLaunch() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              !CommandLine.arguments.contains("--preview"),
              !CommandLine.arguments.contains("--state-directory") else { return }
        _ = try registerIfNeeded()
    }

    @discardableResult
    static func registerIfNeeded(defaults: UserDefaults = .standard,
                                 status: () -> SMAppService.Status = { SMAppService.mainApp.status },
                                 register: () throws -> Void = { try SMAppService.mainApp.register() }) throws -> SMAppService.Status {
        let current = status()
        // An old "configured" flag is not proof that macOS registered the app.
        // Only an explicit opt-out or the actual service status can skip this.
        guard defaults.object(forKey: "launchAtLoginEnabled") as? Bool != false,
              current == .notRegistered || current == .notFound else { return current }
        try register()
        let actual = status()
        guard actual == .enabled || actual == .requiresApproval else {
            throw NagaError.unavailable("macOS did not enable login registration. Try again from the Naga menu.")
        }
        defaults.set(true, forKey: "launchAtLoginEnabled")
        return actual
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !Self.enabled { try SMAppService.mainApp.register() }
            guard Self.enabled || requiresApproval else {
                throw NagaError.unavailable("macOS did not enable login registration.")
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(enabled, forKey: "launchAtLoginEnabled")
    }

    static func shouldOpenWindowAtLaunch(arguments: [String], event: NSAppleEventDescriptor?, isHidden: Bool = false) -> Bool {
        guard !arguments.contains("--background"), !isHidden else { return false }
        if ["--show-window", "--preview", "--state-directory", "--permission-relaunch"].contains(where: arguments.contains) {
            return true
        }
        // A login item can start without an Apple event. Require an explicit
        // open request before presenting a window on an ordinary launch.
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem
            && event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) == nil
            && event.attributeDescriptor(forKeyword: keyAELaunchedAsLogInItem) == nil
    }
}
