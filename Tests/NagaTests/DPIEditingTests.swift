import Testing
import NagaCore
@testable import Naga

@Test(arguments: [0, 1, 2, 3, 4]) @MainActor
func deletingAStagePreservesTheActiveValueUnlessThatStageWasDeleted(index: Int) throws {
    let model = AppModel(preview: true)
    let originalHardware = model.hardware
    let originalAssignments = model.profile?.assignments

    model.removeStage(index)

    let dpi = try #require(model.profile?.dpi)
    #expect(dpi.stages.count == 4)
    #expect(dpi.active == [2, 2, 3, 3, 3][index])
    #expect(dpi.stages[dpi.active - 1].x == [1600, 1600, 2400, 1600, 1600][index])
    #expect(model.profile?.assignments == originalAssignments)
    #expect(model.hardware == originalHardware)
    #expect(model.canApply)
}

@Test @MainActor func deletingTheActiveLastStageSelectsThePreviousStage() throws {
    let model = AppModel(preview: true)
    model.profile?.dpi.active = 5

    model.removeStage(4)

    #expect(model.profile?.dpi.active == 4)
    #expect(model.profile?.dpi.stages.last?.x == 2400)
    try model.profile?.validate()
}

@Test @MainActor func theLastDPIStageCannotBeDeleted() throws {
    let model = AppModel(preview: true)
    for _ in 0..<4 { model.removeStage(0) }
    let lastStageProfile = model.profile

    model.removeStage(0)

    #expect(model.profile == lastStageProfile)
    #expect(model.profile?.dpi.stages.count == 1)
    #expect(model.profile?.dpi.active == 1)
    try model.profile?.validate()
}

@Test @MainActor func invalidStageIndicesLeaveTheDraftUntouched() throws {
    let model = AppModel(preview: true)
    let original = model.profile

    model.removeStage(-1)
    model.removeStage(5)
    model.removeStage(100)

    #expect(model.profile == original)
}

@Test @MainActor func bothSectionsEditTheSameSelectedApplicationWithoutChangingTheDefault() throws {
    let model = AppModel(preview: true)
    let original = try #require(model.profile)
    let target = ApplicationProfile.Target.bundleIdentifier("com.example.Game")
    model.addApplicationProfile(target: target, name: "Game")
    #expect(model.selectedDPI == original.dpi)
    model.setAction(.disabled)

    model.selectedSection = "dpi"
    model.useApplicationDPI(true)
    model.removeStage(0)
    model.setStage(0, value: 900)
    model.selectStage(0)
    #expect(model.selectedApplication?.dpi?.stages.count == 4)
    #expect(model.selectedApplication?.dpi?.stages.first?.x == 900)
    #expect(model.selectedApplication?.dpi?.active == 1)
    #expect(model.profile == original)

    model.selectedSection = "buttons"
    #expect(model.selectedAction == .disabled)
    model.selectedApplicationTarget = nil
    #expect(model.selectedDPI == original.dpi)
    #expect(model.selectedAction == original.assignments.first?.action)
    model.selectedApplicationTarget = target
    model.useApplicationDPI(false)
    #expect(model.selectedDPI == original.dpi)
}
