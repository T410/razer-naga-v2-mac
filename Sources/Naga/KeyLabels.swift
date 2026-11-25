import AppKit
import Carbon
import NagaCore

enum KeyLabels {
    static func label(_ code: UInt16, event: NSEvent? = nil) -> String {
        let special: [UInt16: String] = [36:"↩", 48:"⇥", 49:"Space", 51:"⌫", 53:"⎋", 117:"⌦",
            123:"←",124:"→",125:"↓",126:"↑",115:"↖",119:"↘",116:"⇞",121:"⇟",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",
            103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        if let name = special[code] { return name }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0; var length = 0; var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                              OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 8, &length, &chars) == noErr, length > 0 {
                let text = String(utf16CodeUnits: chars, count: length)
                if text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return text.uppercased() }
            }
        }
        return event?.charactersIgnoringModifiers?.uppercased() ?? "Key \(code)"
    }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }; if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }; if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.function) { m.insert(.fn) }
        return m
    }
    static func eventFlags(for shortcut: Shortcut) -> CGEventFlags {
        let modifiers = shortcut.modifiers
        var f: CGEventFlags = []
        if modifiers.contains(.command) { f.insert(.maskCommand) }; if modifiers.contains(.control) { f.insert(.maskControl) }
        if modifiers.contains(.option) { f.insert(.maskAlternate) }; if modifiers.contains(.shift) { f.insert(.maskShift) }
        if modifiers.contains(.fn) { f.insert(.maskSecondaryFn) }
        // macOS marks arrow events as extended keys, independently of a held Fn key.
        if (123...126).contains(shortcut.keyCode) { f.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        return f
    }
}
