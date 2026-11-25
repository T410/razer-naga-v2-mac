import SwiftUI
import NagaCore

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recording: Bool
    var shortcut: Shortcut?
    var onCapture: (Shortcut) -> Void
    func makeNSView(context: Context) -> RecorderView { RecorderView() }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.onCapture = { value in onCapture(value); recording = false }
        view.onCancel = { recording = false }
        view.title = recording ? "Press a shortcut…" : (shortcut?.label ?? "Record Shortcut")
        view.recording = recording
        view.onStart = { recording = true }
        if recording, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        view.beginSystemCaptureIfFocused()
    }
    static func dismantleNSView(_ view: RecorderView, coordinator: ()) { view.cancelRecording() }
    final class RecorderView: NSView {
        var onCapture: ((Shortcut) -> Void)?
        var onCancel: (() -> Void)?
        var onStart: (() -> Void)?
        var title = "" { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
        var recording = false {
            didSet {
                if recording { beginSystemCaptureIfFocused() }
                else { systemCapture.end(); fnHeld = false }
                needsDisplay = true
            }
        }
        private var fnHeld = false
        private let systemCapture = SystemShortcutCapture()
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.button)
            setAccessibilityHelp("Click to record a keyboard shortcut.")
            NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned), name: NSApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { NotificationCenter.default.removeObserver(self); systemCapture.end() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if recording { window?.makeFirstResponder(self); beginSystemCaptureIfFocused() }
        }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { beginSystemCaptureIfFocused() }
            return accepted
        }
        fileprivate func beginSystemCaptureIfFocused() {
            guard recording, window?.firstResponder === self, window?.isKeyWindow == true else { return }
            systemCapture.begin()
        }
        func cancelRecording() {
            let wasRecording = recording
            recording = false
            systemCapture.end()
            if wasRecording { onCancel?() }
        }
        @objc private func applicationResigned(_ notification: Notification) { cancelRecording() }
        @objc private func windowResigned(_ notification: Notification) {
            if notification.object as? NSWindow === window { cancelRecording() }
        }
        override func accessibilityPerformPress() -> Bool { onStart?(); return true }
        override func mouseDown(with event: NSEvent) { fnHeld = NSEvent.modifierFlags.contains(.function); onStart?(); window?.makeFirstResponder(self) }
        override func flagsChanged(with event: NSEvent) {
            if event.keyCode == 63 { fnHeld = event.modifierFlags.contains(.function) }
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { if event.keyCode == 36 || event.keyCode == 49 { onStart?() }; return }
            if event.keyCode == 53 { cancelRecording(); window?.makeFirstResponder(nil); return }
            var modifiers = KeyLabels.modifiers(event.modifierFlags)
            // Extended keys carry the function flag even when Fn isn't physically held.
            if !fnHeld { modifiers.remove(.fn) }
            let captured = Shortcut(keyCode: event.keyCode, modifiers: modifiers, keyLabel: KeyLabels.label(event.keyCode, event: event))
            recording = false
            onCapture?(captured)
            window?.makeFirstResponder(nil)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self, event.type == .keyDown else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }
        override func resignFirstResponder() -> Bool { cancelRecording(); return true }
        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.1) : NSColor.controlBackgroundColor).setFill(); path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); path.lineWidth = recording ? 2 : 1; path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.labelColor]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
