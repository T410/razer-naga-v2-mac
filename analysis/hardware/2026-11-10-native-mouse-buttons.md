# Mouse4 / Mouse5: implementation and hardware verification

Date: November 10, 2026. Device: Razer Naga V2 HyperSpeed, RZ01-0360, 2.4 GHz USB receiver `1532:00B4`.

## App behavior

Each side button and wheel tilt editor has an **Assignment** menu. The user can choose **Mouse4 · Mouse button 4**, **Mouse5 · Mouse button 5** or **Record Keyboard Shortcut…**. Choosing a mouse button creates an unapplied draft change; writing starts only with **Apply**. Switching to keyboard recording and cancelling with Esc preserves the previous mouse button selection; this transition was verified in the native interface.

Assignments run from mouse memory and are backed up on the Mac with the full profile. They do not require Mac-side event generation or continuous routing. Mouse4/Mouse5 back/forward behavior depends on the receiving app's support; navigation is not guaranteed across Finder, Steam or Wine.

The Razer mouse function uses ordinals: `01 01 04 00 00 00 00` for Mouse4 and `01 01 05 00 00 00 00` for Mouse5. USB button bitmasks 8/16 are not used in this configuration field. Protocol information was checked against [OpenNaga OnboardProfilePlan](https://github.com/Zer0codestuff/OpenNaga/blob/main/Sources/NagaController/Hardware/OnboardProfilePlan.swift); reference code was not run. The app decodes only these two exact function descriptors; unrecognized function bytes are preserved.

## Verification

46 device-independent tests passed: 33 core tests and 13 app tests. New checks cover ordinal and packet encoding, no writes outside the two tilts, decoding mouse assignments on readback, restoring hardware and the Mac profile after partial write failures, coexistence with shortcuts running on the Mac, preserving unknown functions and undoing draft changes. The native Xcode Debug/arm64 build and signature verification passed.

Input Monitoring access was renewed for the current app. The app's **Button Assignments → tilt → Assignment → Mouse4/Mouse5 → Apply** flow was used on the physical device.

| Control | Before | After |
|---|---|---|
| Left tilt `0x34` | ⌘→ | Mouse4 |
| Right tilt `0x35` | ⌘← | Mouse5 |
| Other 14 raw button functions | Pre-operation snapshot | Identical |
| DPI stages | 1000 / 1200 / 1600 / 2000 | Identical |
| Active stage / X-Y DPI | 2 / 1200-1200 | Identical |
| Raw DPI table, device mode and identity | Pre-operation snapshot | Identical |

- An independent pre-write snapshot was saved as `before-apply-device.json`. The app's pre-operation backup hardware snapshot matched it exactly; the complete previous Mac profile also matched a separate initial copy.
- The app verified each write by reading both stored and active assignments. Both assignments were saved as Mouse4/Mouse5 in the Mac profile; no other Mac assignment changed and no local routes were added.
- The previously saved Mac profile contained active stage 1, but this did not change the current stage 2 selected with the physical mouse button. The final profile stores the hardware's current active stage 2.
- Naga was fully closed. An independent `--diagnose` read exactly matched the last saved hardware snapshot.
- The user physically used both tilt directions once. Read-only diagnostics watching only Button usage page inputs 4/5 on this receiver observed press/release pairs for both buttons. No keyboard input was monitored, no events were generated and no settings were written.
- No recovery record remained. After reopening, Naga showed Mouse4/Mouse5, a 2.4 GHz connection and no unapplied changes. The two requested assignments were left on the mouse; the previous Command-arrow assignments were not restored.

## Local evidence and limits

Evidence directory: `build/mouse4-mouse5-20261110/`, covered by `.gitignore`. Files may contain a serial number.

- `before-device.json`: initial hardware read before permission renewal.
- `before-apply-device.json`, `before-mac-profile.json`: initial snapshots for comparison.
- `previous-backup.json`: full hardware and Mac backup saved by the app before writing.
- `after-device.json`, `after-mac-profile.json`: independent final read and complete saved profile.
- `input-events.json`: physical Mouse4/Mouse5 press/release inputs observed with Naga closed.
- `manifest.json`: SHA-256 hashes of evidence files.

Read-only helper: `Scripts/watch-mouse-buttons.swift`. Build: `swiftc -framework IOKit Scripts/watch-mouse-buttons.swift -o /tmp/naga-watch-mouse-buttons`; run: `/tmp/naga-watch-mouse-buttons --output /tmp/naga-mouse-events.json`. It listens for up to 60 seconds and exits when both press/release pairs complete. It may require Input Monitoring access.

Persistence after power loss, Bluetooth and navigation behavior in target apps were outside this verification's scope. Disconnection and partial write failures were not forced on the real device; rollback was verified with device-independent tests. Firmware, device mode, drivers and persistent system keyboard shortcuts were unchanged.
