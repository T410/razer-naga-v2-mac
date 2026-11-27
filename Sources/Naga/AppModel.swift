import AppKit
import Combine
import NagaCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let defaultApplicationName = "Default (macOS)"

    @Published var profile: MouseProfile?
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var checking = false
    @Published private(set) var needsInputAccess = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var notice: String?
    @Published var error: String?
    @Published var selectedControl: UInt8 = 0x40
    @Published var selectedSection = "buttons"
    @Published var recording = false
    @Published private(set) var applicationProfiles: [ApplicationProfile] = []
    @Published var selectedApplicationTarget: ApplicationProfile.Target? { didSet { recording = false } }
    @Published private(set) var activeApplicationName: String?
    @Published private(set) var switchingDPI = false
    @Published private(set) var hardware: DeviceState?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var launchAtLoginIssue: String?
    @Published private(set) var renewingPermission = false
    private(set) var restartingForPermissions = false
    let permissionSetup: PermissionSetup
    private var checkingInitialStartup = false
    private var requestedLoginApproval = false
    private var loadedProfile: MouseProfile?
    private var loadedApplicationProfiles: [ApplicationProfile] = []
    private var relinkedWineTarget: ApplicationProfile.Target?
    private var requiresApplicationApply = false
    private var committed: SavedProfile?
    private let queue = DispatchQueue(label: "Naga.device", qos: .userInitiated)
    private let directory: URL
    private var repository: ProfileRepository?
    private var timer: Timer?
    private var wineFocusTimer: Timer?
    private var dpiSwitchTask: Task<Void, Never>?
    private var requestedDPI: DPISettings?
    private var appliedDPI: DPISettings?
    private var failedDPI: DPISettings?
    private var quitting = false
    private var sleeping = false
    private var routingAvailable = false
    private let router: InputRouter
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    let preview: Bool

    var dirty: Bool { profile != loadedProfile || applicationProfiles != loadedApplicationProfiles || requiresApplicationApply }
    var macCount: Int {
        let shortcuts = profile?.assignments.filter(\.action.needsMac).map(\.id) ?? []
        let overrides = applicationProfiles.flatMap { $0.assignments.map(\.id) }
        return Set(shortcuts + overrides).count
    }
    var canEdit: Bool { connected && !busy && !needsRecovery && !renewingPermission }
    var canApply: Bool {
        canEdit && !switchingDPI && dirty && !recording && profile.map { (try? $0.validate()) != nil } == true
            && applicationProfiles.allSatisfy { $0.dpi.map { (try? $0.validate()) != nil } ?? true }
    }
    var editingApplication: Bool { selectedApplication != nil }
    var selectedApplication: ApplicationProfile? { applicationProfiles.first { $0.id == selectedApplicationTarget } }
    var selectedDPI: DPISettings? { selectedApplication?.dpi ?? profile?.dpi }
    var selectedAction: ButtonAction { action(for: selectedControl) }
    var canOverrideSelectedAction: Bool { defaultAction(for: selectedControl) != .original }
    var inheritsSelectedAction: Bool { !hasApplicationOverride(for: selectedControl) }
    var selectedTitle: String { MouseControl.all.first { $0.id == selectedControl }?.title ?? "Button" }
    var stateDirectory: URL { directory }
    var canRecordSystemShortcuts: Bool { AXIsProcessTrusted() }
    var inputRoutingReady: Bool { router.ready }

    func actionNeedsMac(_ control: UInt8) -> Bool {
        if editingApplication, hasApplicationOverride(for: control) { return true }
        if defaultAction(for: control).needsMac { return true }
        guard applicationProfiles.contains(where: { $0.assignments.contains { $0.id == control } }) else { return false }
        guard let profile, let hardware,
              let plan = try? ApplyPlan(profile: profile, baseline: hardware, applicationProfiles: applicationProfiles) else { return true }
        return plan.applicationTriggers.contains { $0.control == control }
    }

    func configureLaunchAtLogin() {
        do { try LoginItem.configureOnFirstLaunch(); launchAtLoginIssue = nil }
        catch { launchAtLoginIssue = error.localizedDescription }
        updateLaunchAtLoginStatus()
    }

    func updateLaunchAtLoginStatus() {
        launchAtLoginEnabled = LoginItem.enabled
        launchAtLoginRequiresApproval = LoginItem.requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !preview else { return }
        do { try LoginItem.setEnabled(enabled); launchAtLoginIssue = nil }
        catch { self.error = error.localizedDescription }
        UserDefaults.standard.set(true, forKey: "initialStartupChoiceHandled")
        updateLaunchAtLoginStatus()
    }

    func beginPermissionSetup() {
        guard !preview, !quitting, !renewingPermission, !checkingInitialStartup, NSApp.isActive,
              NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        checkingInitialStartup = true
        if !CommandLine.arguments.contains("--state-directory"),
           !UserDefaults.standard.bool(forKey: "initialStartupChoiceHandled") {
            UserDefaults.standard.set(true, forKey: "initialStartupChoiceHandled")
            updateLaunchAtLoginStatus()
            if !launchAtLoginEnabled, !launchAtLoginRequiresApproval {
                let alert = NSAlert()
                alert.messageText = "Start \(AppIdentity.name) at login?"
                alert.informativeText = "The app runs in the background without opening a window and keeps per-app button assignments active."
                alert.addButton(withTitle: "Enable")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() == .alertFirstButtonReturn { setLaunchAtLogin(true) }
                else { UserDefaults.standard.set(false, forKey: "launchAtLoginEnabled") }
            }
        }
        checkingInitialStartup = false
        updateLaunchAtLoginStatus()
        if launchAtLoginRequiresApproval {
            if !requestedLoginApproval {
                requestedLoginApproval = true
                SMAppService.openSystemSettingsLoginItems()
            }
            return
        }
        permissionSetup.begin(needsAccessibility: true)
    }

    func completePermissionSetup() {
        guard !preview, !renewingPermission, !busy, !switchingDPI else { return }
        recording = false
        if launchAtLoginIssue != nil { setLaunchAtLogin(true) }
        updateLaunchAtLoginStatus()
        if launchAtLoginRequiresApproval {
            requestedLoginApproval = true
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        if case .renew(let permission) = permissionSetup.continueSetup(needsAccessibility: true) { renewPermission(permission) }
        refresh(silent: true)
    }

    func hasUnappliedChange(_ control: UInt8) -> Bool {
        if editingApplication {
            let saved = savedApplicationForSelection()
            return selectedApplication?.assignments.first { $0.id == control } != saved?.assignments.first { $0.id == control }
        }
        guard let draft = profile?.assignments.first(where: { $0.id == control }),
              let saved = loadedProfile?.assignments.first(where: { $0.id == control }) else { return false }
        return draft.action != saved.action
    }

    private func defaultAction(for control: UInt8) -> ButtonAction {
        profile?.assignments.first { $0.id == control }?.action ?? .original
    }

    func action(for control: UInt8) -> ButtonAction {
        if editingApplication, let action = selectedApplication?.assignments.first(where: { $0.id == control })?.action { return action }
        return defaultAction(for: control)
    }

    func hasApplicationOverride(for control: UInt8) -> Bool {
        selectedApplication?.assignments.contains { $0.id == control } == true
    }

    init(preview: Bool = false, directory: URL? = nil, router: InputRouter = InputRouter(), permissionSetup: PermissionSetup? = nil) {
        self.preview = preview
        self.router = router
        self.permissionSetup = permissionSetup ?? PermissionSetup()
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Naga", isDirectory: true)
        if preview { installPreview(); return }
        do { repository = try ProfileRepository(directory: self.directory) }
        catch { self.error = error.localizedDescription; return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh(silent: true) } }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.updateInputRoutes(foreground: app) }
        }
        refresh(silent: true)
    }

    func handleSleep() {
        connected = false
        sleeping = true
        appliedDPI = nil
        updateInputRoutes()
    }

    func handleWake() {
        sleeping = false
        router.restart()
        updateInputRoutes()
        refresh(silent: true)
    }

    func refresh(silent: Bool = true) {
        guard !preview, !quitting, !sleeping, !renewingPermission, !busy, !checking, !switchingDPI, !recording, let repository else { return }
        permissionSetup.refresh(needsAccessibility: true)
        if !silent { failedDPI = nil }
        needsInputAccess = !HIDMouseIO.hasInputAccess
        guard !needsInputAccess else { connected = false; routingAvailable = false; updateInputRoutes(); return }
        checking = true
        queue.async { [weak self] in
            let result = Result { () -> (DeviceState, SavedProfile?, Bool) in
                let io = try HIDMouseIO(directory: repository.directory)
                defer { io.close() }
                let state = try DeviceState.read(from: io)
                let saved = try repository.saved(serial: state.serial)
                try repository.ensureInitial(DeviceBackup(hardware: state, local: saved))
                return (state, saved, try repository.recovery(serial: state.serial) != nil)
            }
            let receiverPresent = HIDMouseIO.receiverPresent
            DispatchQueue.main.async { [weak self] in
                self?.completeRefresh(result, receiverPresent: receiverPresent, silent: silent)
            }
        }
    }

    func completeRefresh(_ result: Result<(DeviceState, SavedProfile?, Bool), Error>, receiverPresent: Bool, silent: Bool) {
        checking = false
        guard !busy, !sleeping, !quitting, !renewingPermission else { return }
        switch result {
        case .success(let (state, saved, recovery)):
            let newConnection = !connected || hardware?.serial != state.serial
            if newConnection {
                appliedDPI = nil
                failedDPI = nil
            }
            connected = true; needsRecovery = recovery
            routingAvailable = true
            if hardware?.serial != state.serial || !dirty {
                do { try adopt(state, saved: saved) }
                catch { if !silent { self.error = error.localizedDescription } }
            } else {
                hardware = state
                if let committed = committed, !committed.recognizesDPIConfiguration(state) {
                    appliedDPI = nil
                }
                if let committed = committed,
                   committed.verifiedSoftwareControls(in: state).count != committed.routingControlCount {
                    requiresApplicationApply = true
                    setCommitted(nil)
                    notice = "The profile triggers on the mouse have changed. Click Apply to enable the profiles again."
                }
            }
            updateInputRoutes()
            if !preview { permissionSetup.refresh(needsAccessibility: true) }
            if recovery { notice = "The previous operation was interrupted. Restore the backup before continuing to edit." }
        case .failure(let error):
            // The USB receiver stays present while the wireless mouse
            // sleeps. Keep verified routes ready for its first wake edge.
            routingAvailable = receiverPresent
            connected = false; appliedDPI = nil; updateInputRoutes()
            if !silent { self.error = error.localizedDescription }
            if !receiverPresent { notice = nil }
        }
    }

    private func adopt(_ state: DeviceState, saved: SavedProfile?) throws {
        hardware = state
        var draft: MouseProfile
        var verified: SavedProfile?
        var needsApply = false
        if let saved, saved.recognizesDPIConfiguration(state) {
            draft = saved.profile
            if saved.applicationProfiles?.contains(where: { $0.dpi != nil }) != true {
                draft.dpi.active = try state.dpi.active
            }
            verified = saved
        } else {
            draft = try state.makeProfile(label: { KeyLabels.label($0) })
            appliedDPI = nil
            if let saved, saved.routingControlCount > 0 {
                let matching = saved.verifiedSoftwareControls(in: state)
                for assignment in saved.profile.assignments where matching.contains(assignment.id) {
                    if let index = draft.assignments.firstIndex(where: { $0.id == assignment.id }) {
                        draft.assignments[index] = assignment
                    }
                }
                if matching.count == saved.routingControlCount { verified = saved }
                else { needsApply = true }
            }
            if needsApply { notice = "The profile triggers on the mouse have changed. Click Apply to enable the profiles again." }
            else if saved != nil { notice = "The mouse has different settings. You can load the Mac backup from the Restore menu." }
        }
        if verified?.canStoreMoreDefaultsOnMouse == true {
            needsApply = true
            notice = "Click Apply to store more default button assignments directly on the mouse."
        }
        profile = draft; loadedProfile = draft
        loadApplications(saved?.applicationProfiles ?? [])
        requiresApplicationApply = needsApply
        setCommitted(verified)
    }

    private func loadApplications(_ profiles: [ApplicationProfile]) {
        loadedApplicationProfiles = profiles
        replaceApplicationDraft(with: profiles)
    }

    private func replaceApplicationDraft(with profiles: [ApplicationProfile]) {
        relinkedWineTarget = nil
        applicationProfiles = profiles
        if selectedApplicationTarget != nil, selectedApplication == nil { selectedApplicationTarget = nil }
    }

    private func savedApplicationForSelection() -> ApplicationProfile? {
        if let relinkedWineTarget, relinkedWineTarget == selectedApplicationTarget {
            return loadedApplicationProfiles.first { $0.id == .unlinkedWineExecutable }
        }
        return loadedApplicationProfiles.first { $0.id == selectedApplicationTarget }
    }

    private func setCommitted(_ saved: SavedProfile?) {
        committed = saved
        let watchesWine = saved?.applicationProfiles?.contains { profile in
            if case .wineExecutable = profile.id { return !profile.assignments.isEmpty || profile.dpi != nil }
            return false
        } == true
        if watchesWine, wineFocusTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateInputRoutes() } }
            RunLoop.main.add(timer, forMode: .common)
            wineFocusTimer = timer
        } else if !watchesWine {
            wineFocusTimer?.invalidate(); wineFocusTimer = nil
        }
        updateInputRoutes()
    }

    private func updateInputRoutes(foreground: NSRunningApplication? = nil) {
        guard routingAvailable, !sleeping, !quitting, !renewingPermission, !busy, !needsRecovery, let committed else {
            router.configure([:]); activeApplicationName = nil; requestDPI(nil); return
        }
        let profiles = committed.applicationProfiles?.filter { !$0.assignments.isEmpty || $0.dpi != nil } ?? []
        let app = foreground ?? NSWorkspace.shared.frontmostApplication
        let focus = profiles.isEmpty ? nil : app.map { ApplicationFocus(app: $0, checkWine: wineFocusTimer != nil) }
        let matched = focus?.match(in: profiles)
        if activeApplicationName != matched?.name { activeApplicationName = matched?.name }
        router.configure(committed.inputActions(for: matched?.id), native: committed.nativeInputActions(for: matched?.id),
                         focusPID: profiles.isEmpty ? nil : app?.processIdentifier)
        requestDPI(connected && profiles.contains { $0.dpi != nil } ? (matched?.dpi ?? committed.profile.dpi) : nil)
    }

    private func requestDPI(_ dpi: DPISettings?) {
        if requestedDPI != dpi {
            requestedDPI = dpi
            failedDPI = nil
            dpiSwitchTask?.cancel()
            dpiSwitchTask = nil
        }
        guard let dpi, dpi != appliedDPI, dpi != failedDPI, dpiSwitchTask == nil, !switchingDPI, !checking else { return }
        dpiSwitchTask = Task { @MainActor [weak self] in
            // Wait for the foreground to settle before writing the hardware DPI table.
            do { try await Task.sleep(for: .milliseconds(650)) }
            catch { return }
            guard let self else { return }
            self.dpiSwitchTask = nil
            self.switchDPI(to: dpi)
        }
    }

    private func switchDPI(to dpi: DPISettings) {
        guard connected, !busy, !checking, !needsRecovery, !switchingDPI,
              let committed, let hardware, let repository else { return }
        switchingDPI = true
        queue.async { [weak self] in
            let result = Result {
                let io = try HIDMouseIO(directory: repository.directory, mayWrite: true)
                defer { io.close() }
                return try ConfigurationWriter(io: io, repository: repository).switchDPI(to: dpi, saved: committed, expected: hardware)
            }
            let recovery = (try? repository.recovery(serial: hardware.serial)) != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.switchingDPI = false
                self.needsRecovery = recovery
                switch result {
                case .success(let state):
                    self.hardware = state
                    self.appliedDPI = dpi
                case .failure:
                    self.failedDPI = dpi
                    // Focus changes are background work. Recovery, if needed,
                    // remains visible without presenting a device-error alert.
                    self.connected = false
                    self.appliedDPI = nil
                    if recovery { self.notice = "The previous operation was interrupted. Restore the backup before continuing to edit." }
                }
                self.updateInputRoutes()
            }
        }
    }

    func setAction(_ action: ButtonAction) {
        if editingApplication { setApplicationAction(action); return }
        guard canEdit, let index = profile?.assignments.firstIndex(where: { $0.id == selectedControl }) else { return }
        profile?.assignments[index].action = action; notice = nil
    }
    func revertSelectedAction() {
        if editingApplication {
            recording = false
            let saved = savedApplicationForSelection()
            setApplicationAction(saved?.assignments.first { $0.id == selectedControl }?.action)
            return
        }
        guard canEdit, let saved = loadedProfile?.assignments.first(where: { $0.id == selectedControl }) else { return }
        recording = false
        setAction(saved.action)
    }

    func setApplicationAction(_ action: ButtonAction?) {
        guard canEdit, action == nil || canOverrideSelectedAction,
              let index = applicationProfiles.firstIndex(where: { $0.id == selectedApplicationTarget }) else { return }
        var assignments = applicationProfiles[index].assignments.filter { $0.id != selectedControl }
        if let action { assignments.append(Assignment(id: selectedControl, action: action)) }
        applicationProfiles[index].assignments = assignments.sorted { $0.id < $1.id }
        notice = nil
    }

    func addApplicationProfile(target: ApplicationProfile.Target, name: String) {
        guard canEdit else { return }
        if !applicationProfiles.contains(where: { $0.id == target }) {
            applicationProfiles.append(ApplicationProfile(target: target, name: name))
        }
        selectedApplicationTarget = target
        notice = nil
    }

    func linkWineProfile(to target: ApplicationProfile.Target) {
        guard canEdit, case .wineExecutable = target,
              let index = applicationProfiles.firstIndex(where: { $0.id == .unlinkedWineExecutable }) else { return }
        guard !applicationProfiles.contains(where: { $0.id == target }) else {
            error = "A profile already exists for the selected .exe file."
            return
        }
        let existing = applicationProfiles[index]
        var linked = ApplicationProfile(target: target, name: existing.name)
        linked.assignments = existing.assignments
        linked.dpi = existing.dpi
        applicationProfiles[index] = linked
        relinkedWineTarget = target
        selectedApplicationTarget = target
        notice = nil
    }

    func removeSelectedApplicationProfile() {
        guard canEdit, let target = selectedApplicationTarget else { return }
        applicationProfiles.removeAll { $0.id == target }
        if relinkedWineTarget == target { relinkedWineTarget = nil }
        selectedApplicationTarget = nil
        notice = nil
    }
    func useApplicationDPI(_ enabled: Bool) {
        guard canEdit, let index = applicationProfiles.firstIndex(where: { $0.id == selectedApplicationTarget }),
              (applicationProfiles[index].dpi != nil) != enabled else { return }
        applicationProfiles[index].dpi = enabled ? profile?.dpi : nil
    }
    private func editDPI(_ edit: (inout DPISettings) -> Void) {
        guard canEdit, var dpi = selectedDPI else { return }
        if editingApplication {
            guard let index = applicationProfiles.firstIndex(where: { $0.id == selectedApplicationTarget }),
                  applicationProfiles[index].dpi != nil else { return }
            edit(&dpi)
            applicationProfiles[index].dpi = dpi
        } else {
            edit(&dpi)
            profile?.dpi = dpi
        }
    }
    func selectStage(_ index: Int) {
        editDPI { if $0.stages.indices.contains(index) { $0.active = index + 1 } }
    }
    func setStage(_ index: Int, value: Int) {
        editDPI { if $0.stages.indices.contains(index) { $0.stages[index] = DPIStage(x: value) } }
    }
    func addStage() {
        editDPI { dpi in
            guard dpi.stages.count < 5, let last = dpi.stages.last else { return }
            dpi.stages.append(DPIStage(x: min(last.x + 400, 30000)))
        }
    }
    func removeStage(_ index: Int) {
        editDPI { dpi in
            guard dpi.stages.count > 1, dpi.stages.indices.contains(index) else { return }
            dpi.stages.remove(at: index)
            dpi.active = index < dpi.active - 1 ? dpi.active - 1 : min(dpi.active, dpi.stages.count)
        }
    }
    func requestInputPermission() {
        guard !preview else { return }
        permissionSetup.request(.inputMonitoring)
        refresh(silent: true)
    }
    func requestAccessibility() {
        guard !preview else { return }
        permissionSetup.request(.accessibility)
    }

    func renewPermission(_ permission: PrivacyPermission) {
        guard !preview, !busy, !switchingDPI, !renewingPermission else { return }
        guard !dirty else {
            error = "Apply or undo unsaved changes before renewing the permission request."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Renew the \(permission.title) permission request?"
        alert.informativeText = "macOS did not grant access for the previous request. Renewing resets only this app's \(permission.title) decision and reopens the app. Permission setup then starts again. Your profiles and mouse settings are preserved."
        alert.addButton(withTitle: "Renew Permission Request")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renewingPermission = true
        updateInputRoutes()
        router.stop()
        Task { @MainActor in
            do {
                // Close event taps and HID readers before revoking their access.
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while router.isRunning {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw NagaError.unavailable("The input listener could not be stopped to renew permissions. Reopen the app and try again.")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume() }
                }
                try await permissionSetup.reset(permission)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                configuration.arguments = ["--permission-relaunch"]
                restartingForPermissions = true
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                    Task { @MainActor in
                        if let error {
                            self.restartingForPermissions = false
                            self.renewingPermission = false
                            self.error = error.localizedDescription
                            self.router.restart()
                            self.updateInputRoutes()
                        } else { NSApp.terminate(nil) }
                    }
                }
            } catch {
                renewingPermission = false
                self.error = error.localizedDescription
                router.restart()
                updateInputRoutes()
            }
        }
    }
    func apply() {
        guard !preview, canApply, let profile, let hardware, let repository else { return }
        if macCount > 0 && !AXIsProcessTrusted() { requestAccessibility(); error = "Grant Accessibility access for shortcuts that run on the Mac, then click Apply again."; return }
        let applicationProfiles = self.applicationProfiles
        busy = true; updateInputRoutes(); notice = nil
        queue.async { [weak self] in
            let result = Result { () -> SavedProfile in
                let io = try HIDMouseIO(directory: repository.directory, mayWrite: true); defer { io.close() }
                return try ConfigurationWriter(io: io, repository: repository).apply(profile, expected: hardware, applicationProfiles: applicationProfiles)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result {
                case .success(let saved):
                    self.hardware = saved.hardware; self.profile = saved.profile; self.loadedProfile = saved.profile
                    self.loadApplications(saved.applicationProfiles ?? [])
                    self.requiresApplicationApply = false
                    self.appliedDPI = (try? saved.hardware.dpi) == saved.profile.dpi ? saved.profile.dpi : nil
                    self.setCommitted(saved)
                    self.notice = "Settings applied and verified. A complete copy was saved on this Mac."
                case .failure(let error): self.error = error.localizedDescription; self.refresh(silent: true)
                }
            }
        }
    }
    func loadMacCopy() {
        guard canEdit, let serial = hardware?.serial, let repository else { return }
        do {
            guard let saved = try repository.saved(serial: serial) else { notice = "No Mac profile has been saved for this mouse yet."; return }
            profile = saved.profile
            replaceApplicationDraft(with: saved.applicationProfiles ?? [])
            notice = "Assignments loaded from the Mac. Click Apply to write them to the mouse."
        } catch { self.error = error.localizedDescription }
    }
    func restore(initial: Bool = false, recovery: Bool = false) {
        guard !preview, connected, !busy, !switchingDPI, let serial = hardware?.serial, let repository else { return }
        busy = true; updateInputRoutes()
        queue.async { [weak self] in
            let result = Result { () -> (DeviceState, SavedProfile?) in
                let backup: DeviceBackup?
                if recovery { backup = try repository.recovery(serial: serial)?.backup }
                else { backup = try initial ? repository.initial(serial: serial) : repository.previous(serial: serial) }
                guard let backup else { throw NagaError.storage("No restore backup was found for this mouse.") }
                let io = try HIDMouseIO(directory: repository.directory, mayWrite: true); defer { io.close() }
                let state = try ConfigurationWriter(io: io, repository: repository).restore(backup)
                return (state, try repository.saved(serial: serial))
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result {
                case .success(let (state, saved)):
                    self.needsRecovery = false
                    self.appliedDPI = nil
                    do { try self.adopt(state, saved: saved); self.notice = "Previous settings restored and verified." }
                    catch { self.error = error.localizedDescription }
                case .failure(let error): self.error = error.localizedDescription; self.refresh(silent: true)
                }
            }
        }
    }
    func shutdown() {
        timer?.invalidate(); wineFocusTimer?.invalidate(); dpiSwitchTask?.cancel(); router.stop()
        for observer in [sleepObserver, wakeObserver, focusObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func restoreDefaultDPIOnQuit(completion: @escaping (Bool) -> Void) -> Bool {
        guard !quitting, connected, !needsRecovery, let saved = committed, let hardware, let repository,
              saved.applicationProfiles?.contains(where: { $0.dpi != nil }) == true else { return false }
        let dpi = saved.profile.dpi
        let stage = dpi.stages[dpi.active - 1]
        if appliedDPI == dpi, (try? hardware.dpi.stages) == dpi.stages { return false }
        if (try? hardware.dpi) == dpi, hardware.dpiX == stage.x, hardware.dpiY == stage.y { return false }

        quitting = true
        switchingDPI = true
        updateInputRoutes()
        queue.async { [weak self] in
            let result = Result {
                let io = try HIDMouseIO(directory: repository.directory, mayWrite: true)
                defer { io.close() }
                return try ConfigurationWriter(io: io, repository: repository).switchDPI(to: dpi, saved: saved, expected: hardware)
            }
            DispatchQueue.main.async {
                guard let self else { completion(true); return }
                self.switchingDPI = false
                switch result {
                case .success: completion(true)
                case .failure:
                    // An idle mouse must not block quitting or macOS logout.
                    // ConfigurationWriter retains any necessary recovery record.
                    completion(true)
                }
            }
        }
        return true
    }

    private func installPreview() {
        let bindings = DeviceState.controlIDs.map { id -> HardwareBinding in
            HardwareBinding(control: id, function: id >= 0x40 ? [2,2,0,UInt8(0x1e + (id - 0x40) % 10),0,0,0] : [1,1,3,0,0,0,0])
        }
        let dpi = DPISettings(stages: [800,1200,1600,2400,3200].map { DPIStage(x: $0) }, active: 3)
        let bytes = try! DPIWire.encode(dpi, preserving: .init(repeating: 0, count: 38))
        let state = DeviceState(serial: "PREVIEW", bindings: bindings, stageBytes: bytes, dpiX: 1600, dpiY: 1600, mode: 0)
        hardware = state; connected = true
        profile = try! state.makeProfile(label: { KeyLabels.label($0) })
        profile?.assignments[0].action = .shortcut(Shortcut(keyCode: 8, modifiers: .command, keyLabel: "C"))
        profile?.assignments[1].action = .shortcut(Shortcut(keyCode: 9, modifiers: .command, keyLabel: "V"))
        loadedProfile = profile
    }
}
