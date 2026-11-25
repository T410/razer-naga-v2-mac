# DPI stage deletion: fix and hardware test

Date: November 9, 2026. Device: Razer Naga V2 HyperSpeed, RZ01-0360, 2.4 GHz USB receiver `1532:00B4`.

## Bug found in a device-independent test

Deleting a stage before the active stage did not decrease the active stage number. In the preview table, with the third stage at 1600 DPI active, deleting stage 1 or 2 incorrectly moved the selection to 2400 DPI. The parameterized test failed in both cases; the bug was found before any write to the physical mouse.

`AppModel.removeStage` now decreases the active stage number when an earlier stage is deleted, preserving the same DPI value. If the active stage is deleted, the next stage in the list is selected; if the deleted stage was last, the previous stage is selected. The final remaining stage cannot be deleted, and invalid indices leave the draft unchanged.

Verification: 28 core safety tests and 8 app model tests passed (36 tests; the deletion test also runs with five separate indices). The native Xcode Debug/arm64 build and app signature verification passed. With user approval, the old Naga Input Monitoring registration was removed for the new build; connection with the current app was verified.

## Hardware result

| Step | Stage count | Values | Active stage / DPI |
|---|---|---|---|
| Initial state | 5 | 400 / 800 / 1600 / 3200 / 6400 | 3 / 1600 |
| After deleting stage 5 and applying | 4 | 400 / 800 / 1600 / 3200 | 3 / 1600 |
| Independent read with Naga closed | 4 | 400 / 800 / 1600 / 3200 | 3 / 1600 |
| Restore from pre-operation backup | 5 | 400 / 800 / 1600 / 3200 / 6400 | 3 / 1600 |
| Independent read after restore | 5 | 400 / 800 / 1600 / 3200 / 6400 | 3 / 1600 |

- Deletion used the app's **Remove stage 5 → Apply** flow; only the inactive 6400 DPI stage was removed.
- The independent pre-test hardware snapshot exactly matched the snapshot in the Mac profile.
- The pre-operation backup contained the complete raw hardware snapshot and full Mac profile; these matched the separate test copies.
- All 16 button functions and all Mac assignments were unchanged after deletion. Active DPI remained 1600/1600.
- An independent read with the app closed exactly matched the saved four-stage snapshot.
- Restore used **Restore Settings Before Last Change**.
- The final independent read exactly matched the initial state for all 16 raw button functions, raw DPI table, active X/Y DPI, device mode and identity.
- The full Mac profile also exactly matched the initial copy. No recovery record remained. At the end, Naga was open in normal mode and connected over 2.4 GHz.

## Local evidence and limits

Evidence directory: `build/dpi-stage-delete-test-20261109/`, covered by `.gitignore`. Files may contain a serial number.

- `before-device.json`, `before-mac-profile.json`
- `after-delete-device.json`, `after-delete-mac-profile.json`
- `after-restore-device.json`, `after-restore-mac-profile.json`
- `manifest.json`: SHA-256 hashes for the six evidence files.

Only deletion of the inactive last stage was tested on real hardware. Deletion of the active stage or an earlier stage, the single-stage limit and invalid-index behavior were verified with device-independent tests. Persistence after power loss, adding stages and writing during disconnection were outside this test's scope. Firmware, device mode and drivers were unchanged.
