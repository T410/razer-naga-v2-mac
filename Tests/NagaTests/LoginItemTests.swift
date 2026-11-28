import Carbon
import Foundation
import ServiceManagement
import Testing
@testable import Naga

private func loginDefaults() -> UserDefaults {
    UserDefaults(suiteName: "NagaLoginItemTests-" + UUID().uuidString)!
}

private func openApplicationEvent() -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
}

@Test func loginWithoutAnAppleEventDoesNotOpenAWindow() {
    #expect(!LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga"], event: nil))
}

@Test func loginAppleEventsDoNotOpenAWindow() {
    let event = openApplicationEvent()
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    #expect(!LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga"], event: event))

    let markedEvent = openApplicationEvent()
    markedEvent.setParam(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
    #expect(!LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga"], event: markedEvent))
}

@Test func manualLaunchOpensItsWindowUnlessLaunchedHidden() {
    let event = openApplicationEvent()
    #expect(LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga"], event: event))
    #expect(!LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga"], event: event, isHidden: true))
    #expect(!LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga", "--background"], event: event))
    #expect(LoginItem.shouldOpenWindowAtLaunch(arguments: ["Naga", "--show-window"], event: nil))
}

@Test(arguments: [SMAppService.Status.notRegistered, .notFound])
func staleStartupFlagsDoNotPreventTheAppFromRequestingRegistration(initial: SMAppService.Status) throws {
    let defaults = loginDefaults()
    defaults.set(true, forKey: "launchAtLoginConfigured")
    var status = initial, requests = 0
    let actual = try LoginItem.registerIfNeeded(defaults: defaults, status: { status }, register: {
        requests += 1; status = .enabled
    })
    #expect(requests == 1)
    #expect(actual == .enabled)
    #expect(defaults.bool(forKey: "launchAtLoginEnabled"))
    _ = try LoginItem.registerIfNeeded(defaults: defaults, status: { status }, register: { requests += 1 })
    #expect(requests == 1)
}

@Test func startupRegistrationRespectsAnExplicitOptOut() throws {
    let defaults = loginDefaults()
    defaults.set(false, forKey: "launchAtLoginEnabled")
    var requests = 0
    let actual = try LoginItem.registerIfNeeded(defaults: defaults, status: { .notRegistered }, register: { requests += 1 })
    #expect(requests == 0)
    #expect(actual == .notRegistered)
}

@Test func anExistingSystemApprovalRequestIsNotRepeatedOrBypassed() throws {
    var requests = 0
    let actual = try LoginItem.registerIfNeeded(defaults: loginDefaults(), status: { .requiresApproval }, register: { requests += 1 })
    #expect(requests == 0)
    #expect(actual == .requiresApproval)
}

@Test func aFailedStartupRequestRemainsRetryable() throws {
    let defaults = loginDefaults()
    var status = SMAppService.Status.notRegistered
    #expect(throws: CocoaError.self) {
        try LoginItem.registerIfNeeded(defaults: defaults, status: { status }, register: { throw CocoaError(.fileReadNoPermission) })
    }
    #expect(defaults.object(forKey: "launchAtLoginEnabled") == nil)
    let actual = try LoginItem.registerIfNeeded(defaults: defaults, status: { status }, register: { status = .enabled })
    #expect(actual == .enabled)
}

@Test func anUnchangedSystemStatusIsNotReportedAsSuccessfulRegistration() throws {
    let defaults = loginDefaults()
    #expect(throws: (any Error).self) {
        try LoginItem.registerIfNeeded(defaults: defaults, status: { .notFound }, register: {})
    }
    #expect(defaults.object(forKey: "launchAtLoginEnabled") == nil)
}
