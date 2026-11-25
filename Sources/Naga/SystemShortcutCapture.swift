import AppKit
import Carbon

/// A temporary, frontmost-app-only Carbon mode. It does not change the user's
/// saved shortcuts or install a global keyboard listener.
final class SystemShortcutCapture {
    private var token: UnsafeMutableRawPointer?
    private let authorized: () -> Bool
    private let push: () -> UnsafeMutableRawPointer?
    private let pop: (UnsafeMutableRawPointer) -> Void

    init(authorized: @escaping () -> Bool = { AXIsProcessTrusted() },
         push: @escaping () -> UnsafeMutableRawPointer? = {
             PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabledExceptUniversalAccess))
         },
         pop: @escaping (UnsafeMutableRawPointer) -> Void = { PopSymbolicHotKeyMode($0) }) {
        self.authorized = authorized; self.push = push; self.pop = pop
    }

    @discardableResult func begin() -> Bool {
        if token != nil { return true }
        guard authorized() else { return false }
        token = push()
        return token != nil
    }

    func end() {
        guard let previous = token else { return }
        token = nil
        pop(previous)
    }

    deinit { end() }
}
