import Foundation
import Testing
@testable import Naga

@MainActor
private final class PermissionSystem {
    var input: InputAccessStatus = .unknown
    var accessibility = false
    var interactive = true
    var inputRequests = 0
    var accessibilityRequests = 0
    var opened: [PrivacyPermission] = []
    var resets: [PrivacyPermission] = []
    var grantInputOnRequest = false
    var grantAccessibilityOnRequest = false

    func controller() -> PermissionSetup {
        PermissionSetup(client: .init(inputStatus: { self.input }, requestInput: {
            self.inputRequests += 1
            if self.grantInputOnRequest { self.input = .granted }
            return self.input == .granted
        }, accessibilityGranted: { self.accessibility }, requestAccessibility: {
            self.accessibilityRequests += 1
            if self.grantAccessibilityOnRequest { self.accessibility = true }
            return self.accessibility
        }, openSettings: { self.opened.append($0) }, reset: { self.resets.append($0) }),
        isInteractive: { self.interactive })
    }
}

@MainActor @Test func accessibilityIsRequestedFirstWithoutOpeningSettingsOrWaitingForTheMouse() {
    let system = PermissionSystem()
    let setup = system.controller()
    setup.begin(needsAccessibility: true)
    #expect(system.inputRequests == 0)
    #expect(system.accessibilityRequests == 1)
    #expect(system.opened.isEmpty)
    setup.refresh(needsAccessibility: true)
    setup.begin(needsAccessibility: true)
    #expect(system.inputRequests == 0)
    #expect(system.accessibilityRequests == 1)
}

@MainActor @Test func listeningIsRequestedOnlyAfterAccessibilityApprovalIfStillMissing() {
    let system = PermissionSystem()
    let setup = system.controller()
    setup.begin(needsAccessibility: true)
    #expect(system.inputRequests == 0)
    system.accessibility = true
    setup.refresh(needsAccessibility: true)
    setup.refresh(needsAccessibility: true)
    #expect(system.inputRequests == 1)
    #expect(system.accessibilityRequests == 1)
    #expect(system.opened.isEmpty)
}

@MainActor @Test func accessibilityThatAlsoGrantsListeningSkipsTheSecondPrompt() {
    let system = PermissionSystem()
    let setup = system.controller()
    setup.begin(needsAccessibility: true)
    system.accessibility = true
    system.input = .granted
    setup.refresh(needsAccessibility: true)
    #expect(system.accessibilityRequests == 1)
    #expect(system.inputRequests == 0)
    #expect(setup.nextPermission == nil)
}

@MainActor @Test func aManualInputRequestAlsoStartsTheRemainingSetupSteps() {
    let system = PermissionSystem()
    let setup = system.controller()
    setup.request(.inputMonitoring)
    system.input = .granted
    setup.refresh(needsAccessibility: true)
    #expect(system.inputRequests == 1)
    #expect(system.accessibilityRequests == 1)
    #expect(system.opened.isEmpty)
}

@MainActor @Test func anAppStartingInTheBackgroundDoesNotPresentPermissionPrompts() {
    let system = PermissionSystem()
    system.interactive = false
    let setup = system.controller()
    setup.begin(needsAccessibility: true)
    setup.refresh(needsAccessibility: true)
    #expect(system.inputRequests == 0)
    #expect(system.accessibilityRequests == 0)
    system.interactive = true
    setup.begin(needsAccessibility: true)
    #expect(system.accessibilityRequests == 1)
}

@MainActor @Test func anExplicitRequestDoesNotSilentlyFailBecauseActivationIsStillChanging() {
    let system = PermissionSystem()
    system.interactive = false
    let setup = system.controller()
    #expect(setup.continueSetup(needsAccessibility: true) == .requested)
    #expect(system.accessibilityRequests == 1)
    #expect(system.resets.isEmpty)
}

@MainActor @Test func continuingDoesNotTreatItsFirstRequestAsAFailedPreviousAttempt() {
    let system = PermissionSystem()
    let setup = system.controller()
    #expect(setup.continueSetup(needsAccessibility: true) == .requested)
    #expect(system.accessibilityRequests == 1)
    #expect(system.resets.isEmpty)
    #expect(setup.continueSetup(needsAccessibility: true) == .renew(.accessibility))
    #expect(system.resets.isEmpty)
    system.accessibility = true
    #expect(setup.continueSetup(needsAccessibility: true) == .requested)
    #expect(system.inputRequests == 1)
    system.input = .granted
    #expect(setup.continueSetup(needsAccessibility: true) == .complete)
}

@MainActor @Test func grantedPermissionsAreNotRequestedAgain() {
    let system = PermissionSystem()
    system.input = .granted
    system.accessibility = true
    let setup = system.controller()
    setup.begin(needsAccessibility: true)
    setup.request(.inputMonitoring)
    setup.request(.accessibility)
    #expect(system.inputRequests == 0)
    #expect(system.accessibilityRequests == 0)
    #expect(setup.inputStatus == .granted)
    #expect(setup.accessibilityGranted)
}

@MainActor @Test func aDeniedInputPermissionIsNotSilentlyResetByTheApp() {
    let system = PermissionSystem()
    system.input = .denied
    system.accessibility = true
    let setup = system.controller()
    setup.begin(needsAccessibility: true)
    setup.refresh(needsAccessibility: true)
    #expect(system.inputRequests == 1)
    #expect(system.resets.isEmpty)
    #expect(system.opened.isEmpty)
    #expect(setup.inputStatus == .denied)
}

@MainActor @Test func settingsAndPermissionRenewalAreSeparateExplicitActions() async throws {
    let system = PermissionSystem()
    let setup = system.controller()
    setup.openSettings(.inputMonitoring)
    #expect(system.opened == [.inputMonitoring])
    #expect(system.inputRequests == 0)
    try await setup.reset(.inputMonitoring)
    #expect(system.resets == [.inputMonitoring])
    #expect(system.accessibilityRequests == 0)
}

@Test func renewalTargetsOnlyThisAppAndTheSelectedPermission() {
    #expect(PrivacyPermission.inputMonitoring.resetArguments == ["reset", "ListenEvent", "com.tayyib.Naga"])
    #expect(PrivacyPermission.accessibility.resetArguments == ["reset", "Accessibility", "com.tayyib.Naga"])
}

@MainActor @Test func previewNeverRequestsOrRenewsSystemPermissions() {
    let system = PermissionSystem()
    let model = AppModel(preview: true, permissionSetup: system.controller())
    model.beginPermissionSetup()
    model.completePermissionSetup()
    model.requestInputPermission()
    model.requestAccessibility()
    model.renewPermission(.inputMonitoring)
    #expect(system.inputRequests == 0)
    #expect(system.accessibilityRequests == 0)
    #expect(system.resets.isEmpty)
}
