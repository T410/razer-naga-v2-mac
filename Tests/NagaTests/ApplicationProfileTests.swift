import Foundation
import NagaCore
import Testing
@testable import Naga

@Test func wineExecutablesTakePrecedenceOverTheirSharedWrapper() {
    let wrapper = "com.sikarugir.SteamWindows242654314"
    let steam = ApplicationProfile(target: .bundleIdentifier(wrapper), name: "Steam")
    let skyrim = ApplicationProfile(target: .wineExecutable("skyrimse.exe"), name: "Skyrim (Wine)")
    let otherGame = ApplicationProfile(target: .wineExecutable("other game.exe"), name: "Other Game (Wine)")
    let profiles = [steam, skyrim, otherGame]

    #expect(ApplicationFocus(bundleIdentifier: wrapper, windowsExecutable: #"C:\Steam\SkyrimSE.exe"#).match(in: profiles)?.id == skyrim.id)
    #expect(ApplicationFocus(bundleIdentifier: wrapper, windowsExecutable: "OTHER GAME.EXE").match(in: profiles)?.id == otherGame.id)
    #expect(ApplicationFocus(bundleIdentifier: wrapper, windowsExecutable: "SkyrimSELauncher.exe").match(in: profiles)?.id == steam.id)
    #expect(ApplicationFocus(bundleIdentifier: wrapper, windowsExecutable: "steam.exe").match(in: profiles)?.id == steam.id)
    #expect(ApplicationFocus(bundleIdentifier: "org.mozilla.firefox", name: "SkyrimSE.exe").match(in: profiles) == nil)
    #expect(ApplicationFocus(name: "SkyrimSE.exe").match(in: profiles)?.id == skyrim.id)
}

@MainActor
@Test func aLegacyWineProfileKeepsItsAssignmentsWhenTheUserLinksAnExecutable() throws {
    let data = Data(#"{"id":{"skyrimWine":{}},"name":"Skyrim (Wine)","assignments":[{"id":64,"action":{"disabled":{}}}]}"#.utf8)
    let profile = try JSONDecoder().decode(ApplicationProfile.self, from: data)
    #expect(profile.id == .unlinkedWineExecutable)
    #expect(profile.assignments == [Assignment(id: 64, action: .disabled)])

    let encoded = try JSONEncoder().encode(profile)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("skyrimWine"))
    #expect(try JSONDecoder().decode(ApplicationProfile.self, from: encoded) == profile)

    let model = AppModel(preview: true)
    model.selectedSection = "applications"
    model.addApplicationProfile(target: profile.id, name: profile.name)
    model.setAction(.disabled)
    model.linkWineProfile(to: .wineExecutable("chosen-game.exe"))
    #expect(model.applicationProfiles.count == 1)
    #expect(model.selectedApplicationTarget == .wineExecutable("chosen-game.exe"))
    #expect(model.selectedApplication?.assignments == profile.assignments)
}

@MainActor
@Test func editingAnApplicationKeepsItsDefaultAssignmentAndClearsAnUndoneOverride() {
    let model = AppModel(preview: true)
    let fallback = model.selectedAction
    model.selectedSection = "applications"
    let target = ApplicationProfile.Target.wineExecutable("skyrimse.exe")
    model.addApplicationProfile(target: target, name: "Skyrim (Wine)")

    #expect(model.selectedAction == fallback)
    #expect(model.inheritsSelectedAction)
    model.setAction(.disabled)
    #expect(model.selectedAction == .disabled)
    #expect(model.hasUnappliedChange(model.selectedControl))
    model.selectedApplicationTarget = nil
    #expect(model.selectedAction == fallback)
    model.setAction(.mouseButton(.button4))
    #expect(model.profile?.assignments.first { $0.id == model.selectedControl }?.action == .mouseButton(.button4))
    model.selectedApplicationTarget = target
    #expect(model.selectedAction == .disabled)
    model.revertSelectedAction()
    #expect(model.selectedAction == .mouseButton(.button4))
    #expect(!model.hasUnappliedChange(model.selectedControl))
    model.removeSelectedApplicationProfile()
    #expect(model.selectedApplicationTarget == nil)
    model.revertSelectedAction()
    #expect(model.selectedAction == fallback)
    #expect(!model.dirty)
}
