# Hardware and restore limits

This app uses the existing macOS IOHID APIs. It does not install drivers, system extensions, firmware or bootloaders. It does not change SIP, security policies or the Keychain.

## Allowed device commands

The app uses the 90-byte Razer feature report format. Class, command, size, bank, layer and physical control ID are validated before sending.

| Operation | Class / command |
|---|---|
| Read serial number | `00 / 82` |
| Read operating mode | `00 / 84` |
| Read active DPI | `04 / 85` |
| Read DPI stages | `04 / 86` |
| Read button assignment | `02 / 8C` |
| Write button assignment | `02 / 0C`, bank 1, standard layer |
| Write DPI stages | `04 / 06`, persistent storage |
| Write / restore active DPI | `04 / 05` |

Only the 12 side buttons, two wheel tilts and two top DPI buttons can be changed. Left/right click and wheel rotation assignments cannot be written. An unknown device mode or incomplete settings response blocks writes. Response identity and XOR checksum are verified. A busy or stale response causes another response read; the write command is not automatically repeated.

## Write procedure

1. Verify the connected mouse's serial number and read its current settings again.
2. Check that another application has not changed the last observed button assignments or DPI stage settings.
3. Atomically save the current raw button assignments, DPI table, active DPI and Mac profile to disk. Synchronize the file, read it back and verify it.
4. Save a recovery record to disk before writing to the device.
5. Write only changed fields. Verify the serial number before and after each write, including restore and rollback operations. Read back and verify every field. Button assignments are verified in both the stored and active banks.
6. Save the complete Mac profile. Remove the recovery record only after completion.

If an operation fails, the attempted writes are rolled back. A write returning an uncertain error is treated as potentially having reached the device. If the connection is lost, the recovery record is retained. No automatic recovery write occurs at the next connection; the user is offered **Restore**. This record is not an offline editing queue.

When per-app DPI stages are enabled, Naga uses the same commands to write the required DPI table and active value on focus changes. Before each switch, it verifies the serial number, button assignments and a known stage table. The switch's recovery record contains the default profile, and the user's previous-settings backup is preserved.

Multi-field writes to mouse flash memory are not atomic. Software cannot guarantee recovery after a connection loss, power loss or hardware failure. A disk backup alone cannot repair a mouse that no longer accepts commands. Hardware verification therefore starts with read-only checks; development does not trigger unsolicited settings writes.

The initial backup contains **the settings observed when the app first connected to the mouse**. It is not assumed to contain factory settings. Only fields the app can change are backed up and restored. The app does not back up firmware.
