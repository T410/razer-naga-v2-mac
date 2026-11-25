import AppKit
import Testing
import NagaCore
@testable import Naga

@Test @MainActor func systemShortcutModeIsRestoredExactlyOnce() {
    var starts = 0, stops = 0
    let token = UnsafeMutableRawPointer(bitPattern: 1)!
    let capture = SystemShortcutCapture(authorized: { true }, push: { starts += 1; return token }, pop: {
        #expect($0 == token); stops += 1
    })
    #expect(capture.begin())
    #expect(capture.begin())
    #expect(starts == 1)
    capture.end(); capture.end()
    #expect(stops == 1)
}

@Test @MainActor func systemShortcutModeRequiresPermissionAndRestoresOnDeallocation() {
    var allowed = false, starts = 0, stops = 0
    var capture: SystemShortcutCapture? = SystemShortcutCapture(authorized: { allowed }, push: {
        starts += 1; return UnsafeMutableRawPointer(bitPattern: 1)!
    }, pop: { _ in stops += 1 })
    #expect(capture?.begin() == false)
    #expect(starts == 0)
    allowed = true
    #expect(capture?.begin() == true)
    capture = nil
    #expect(starts == 1)
    #expect(stops == 1)
}

@Test(arguments: [(UInt16(123), "←", UInt8(0x50)), (124, "→", 0x4f), (125, "↓", 0x51), (126, "↑", 0x52)]) @MainActor
func controlArrowsRecordAsHardwareShortcutsWithoutAnAccidentalFnFlag(code: UInt16, label: String, usage: UInt8) throws {
    let view = ShortcutRecorder.RecorderView()
    var captured: Shortcut?
    var cancelled = false
    view.onCapture = { captured = $0 }
    view.onCancel = { cancelled = true }
    view.recording = true
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.control, .function], timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))

    view.keyDown(with: event)

    let shortcut = try #require(captured)
    #expect(shortcut.modifiers == .control)
    #expect(shortcut.keyLabel == label)
    #expect(shortcut.hardwareFunction == [2, 2, 1, usage, 0, 0, 0])
    #expect(KeyLabels.eventFlags(for: shortcut) == [.maskControl, .maskSecondaryFn, .maskNumericPad])
    #expect(!view.recording)
    #expect(!cancelled)
}


@Test @MainActor func escapeCancelsRecordingWithoutReplacingTheAssignment() throws {
    let view = ShortcutRecorder.RecorderView()
    var captured = false, cancellations = 0
    view.onCapture = { _ in captured = true }
    view.onCancel = { cancellations += 1 }
    view.recording = true
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))

    view.keyDown(with: escape)
    view.cancelRecording()

    #expect(!captured)
    #expect(cancellations == 1)
    #expect(!view.recording)
}
