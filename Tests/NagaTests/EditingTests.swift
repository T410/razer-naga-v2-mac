import Testing
import NagaCore
@testable import Naga

@Test @MainActor func undoRestoresTheSavedShortcutInsteadOfAnOpaqueOriginalAction() throws {
    let model = AppModel(preview: true)
    let savedAction = model.selectedAction
    let hardware = model.hardware
    model.setAction(.disabled)
    #expect(model.hasUnappliedChange(0x40))
    #expect(model.canApply)

    model.revertSelectedAction()

    #expect(model.selectedAction == savedAction)
    #expect(model.selectedAction.label == "⌘C")
    #expect(!model.hasUnappliedChange(0x40))
    #expect(!model.dirty)
    #expect(!model.canApply)
    #expect(model.hardware == hardware)
}

@Test @MainActor func undoOnlyAffectsTheSelectedControlAndPreservesOtherDraftEdits() throws {
    let model = AppModel(preview: true)
    model.selectedControl = 0x41
    model.setAction(.disabled)
    model.setStage(0, value: 900)
    model.selectedControl = 0x40
    model.setAction(.disabled)

    model.revertSelectedAction()

    #expect(!model.hasUnappliedChange(0x40))
    #expect(model.hasUnappliedChange(0x41))
    #expect(model.profile?.assignments.first(where: { $0.id == 0x41 })?.action == .disabled)
    #expect(model.profile?.dpi.stages[0].x == 900)
    #expect(model.dirty)
    #expect(model.canApply)
}

@Test @MainActor func undoCancelsRecordingAndDiscardsAnUnappliedMacOnlyShortcut() throws {
    let model = AppModel(preview: true)
    model.setAction(.shortcut(Shortcut(keyCode: 8, modifiers: [.fn, .command], keyLabel: "C")))
    #expect(model.macCount == 1)
    model.recording = true

    model.revertSelectedAction()

    #expect(!model.recording)
    #expect(model.macCount == 0)
    #expect(model.selectedAction.label == "⌘C")
    #expect(!model.dirty)
}

@Test @MainActor func editingBackToTheSavedShortcutClearsItsPendingIndicator() throws {
    let model = AppModel(preview: true)
    let savedAction = model.selectedAction
    model.setAction(.disabled)
    #expect(model.hasUnappliedChange(0x40))

    model.setAction(savedAction)

    #expect(!model.hasUnappliedChange(0x40))
    #expect(!model.dirty)
}

@Test @MainActor func mouseButtonSelectionIsAnEditableOnboardActionWithUndo() throws {
    let model = AppModel(preview: true)
    let hardware = model.hardware
    model.selectedControl = 0x34
    let original = model.selectedAction
    model.setAction(.mouseButton(.button4))
    #expect(model.selectedAction.label == "Mouse4")
    #expect(model.hasUnappliedChange(0x34))
    #expect(model.macCount == 0)
    #expect(model.canApply)
    model.revertSelectedAction()
    #expect(model.selectedAction == original)
    #expect(!model.hasUnappliedChange(0x34))
    #expect(model.hardware == hardware)
    #expect(!model.dirty)
}
