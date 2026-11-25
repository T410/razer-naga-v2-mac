# First hardware test: one side button

Date: November 9, 2026. Device: Razer Naga V2 HyperSpeed, RZ01-0360, USB receiver `1532:00B4`, 2.4 GHz connection.

## Scope and result

With the user's approval for a physical device test, only side button 1 was temporarily changed to send `A` instead of `1`. The app's normal **Apply** action performed the write; **Restore Settings Before Last Change** performed the restore. No separate test protocol or unverified direct write path was used.

| Check | Result |
|---|---|
| Read-only diagnostics before writing | Read 16 functions, 5 DPI stages and active 1600/1600 DPI |
| Initial backup verification | Backup exactly matched independent diagnostic output |
| Temporary assignment write | Successful; the app completed readback verification from stored bank 1 and active bank 0 |
| Changed raw fields | Only side button 1 (`0x40`) |
| Unchanged fields | Other 15 functions, raw DPI table, active DPI, device identity and mode |
| Physical test with Naga closed | User confirmed that side button 1 typed `a`; `Aaaaa` was observed in TextEdit |
| Independent read after closing the app | Exactly matched the saved new hardware snapshot |
| Restore from backup | Successful; app verification completed |
| Independent read after restore | Exactly matched the pre-test raw snapshot |
| TextEdit observation after restore | `111111111` appeared on the second line; the physical input source was not independently measured |
| Final state | No pending recovery record; temporary active Mac profile removed; backups preserved; Naga closed |

Raw assignment change:

```text
Before / after restore:    [02 01 00 1e 00 00 00]  (1)
Temporary test assignment: [02 02 00 04 00 00 00]  (A)
```

## Local evidence

Test directory: `build/hardware-test-20261109/`. This directory is covered by `.gitignore`; filenames and contents may contain the device serial number.

- `initial-*.json`: initial, unchanged backup. SHA-256: `08f21574dd9d3fb39525419d2612350682ace81c76124a91af9630ea3f29ff8d`.
- `previous-*.json`, `backup-*.json`: backups taken before writing.
- `saved-*.json`: archived complete Mac profile and hardware snapshot for the temporary assignment.
- `after-apply.json`: independent read-only diagnostics with Naga closed.
- `after-restore.json`: independent read-only diagnostics after restore.

The current source was built with Xcode in Debug/arm64 under `/tmp/naga-hardware-build/`. On first launch, the access check reported no permission, although Naga access was already enabled in System Settings. Restarting the app was sufficient. Permissions and drivers were not changed.

## Limits

This result verifies configuring one side button, using it with the app closed and restoring the settings from backup. This test did not cover DPI writes, other side buttons, wheel tilts, shortcuts running on the Mac, Bluetooth, persistence after power loss or actual disconnection. Firmware, bootloader, device mode and drivers were not changed.
