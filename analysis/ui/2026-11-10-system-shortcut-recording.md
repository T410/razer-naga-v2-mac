# Recording Control + Arrow shortcuts

Date: November 10, 2026.

## Problem and change

The user reported that Control + Left/Right Arrow did not appear in the recording field. The recorder handled only AppKit keyboard events delivered to it; there was no recording mode for symbolic shortcuts used by macOS.

`SystemShortcutCapture` uses the `PushSymbolicHotKeyMode` / `PopSymbolicHotKeyMode` APIs published in Apple's macOS SDK. While the recording field has focus, system symbolic shortcuts are temporarily suspended if Accessibility access is granted. Universal Access shortcuts are preserved. Persistent keyboard shortcut preferences are unchanged; no global keyboard listener was added.

The mode is released when a key is recorded, Esc cancels recording, the first responder changes, window focus or app activation is lost, or the view is removed. The mode object also releases any remaining token on deallocation. The Carbon API additionally restores the previous mode when the app deactivates or exits.

The recorder also captures app menu commands during recording. For example, Command-Q can be recorded as a shortcut rather than quitting the app while recording is active.

## Verification

- 28 NagaCore and 12 app tests passed: 40 tests total. Parameterized tests additionally run two arrow directions and five stage deletion cases with separate arguments.
- Mock push/pop functions verified that temporary mode does not start without permission, repeated starts acquire only one token, the token is released once and deallocation cleans it up. Tests do not change the actual system shortcut mode.
- Synthetic in-app NSEvent tests converted Control + Left/Right Arrow to the correct HID keyboard functions. The extended arrow event's Function flag was not incorrectly recorded as an Fn modifier.
- Esc cancellation left the assignment unchanged and sent only one cancellation notification.
- The final native Xcode Debug/arm64 build and app signature verification passed.
- Actual interface interaction in hardware-free **Preview** mode recorded `⌃←` and `⌃→`. Both appeared as **Stored on Mouse**, without an extra Fn modifier or Runs on Mac indicator.
- In the same preview, Esc preserved the existing draft. During recording, Command-Q was captured as `⌘Q`; outside recording, it quit the app normally.
- The user granted Accessibility access to the new build in the system dialog. macOS displayed this setting as **Device Control and Data Access**.
- After preview ended, Naga opened in normal mode: connected over 2.4 GHz, showing the actual current assignments, with no unapplied changes.

No mouse settings were written during verification of this fix. Persistent system preferences for physical keyboard shortcuts were unchanged. Accessibility access was granted to the new build by the user.

## Source and limits

Temporary mode behavior was checked against the local Apple SDK header: `Carbon.framework/Frameworks/HIToolbox.framework/Headers/CarbonEvents.h`, including the descriptions of `PushSymbolicHotKeyMode`, `PopSymbolicHotKeyMode` and `kHIHotKeyModeAllDisabledExceptUniversalAccess`.

This test verifies recording two Control-arrow combinations. It does not establish compatibility with every macOS system key or another app's global shortcuts. Accessibility shortcuts intentionally remain active during recording.
