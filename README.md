# Razer NAGA v2 for macOS

Configure button assignments and DPI stages on a **Razer Naga V2 HyperSpeed (RZ01-0360)** using its **2.4 GHz USB receiver**. Requires macOS 26 or later. This project is independent of Razer.

## Why do I need this?

I couldn't reassign the buttons on my Naga V2 HyperSpeed with Razer Synapse on my Mac, so I built this app for my own use. It lets you reassign the buttons and make full use of the mouse. I'm sharing it for other Mac users with the same model.

## Supported connection

- **Naga V2 HyperSpeed only.** Naga V2 Pro and other models are not supported.
- **USB receiver only** (`1532:00B4`). Bluetooth configuration is not implemented or tested.
- Connect one compatible receiver at a time. The app selects the USB mouse interface and checks its 90-byte feature report format.

The app reads the mouse's serial number to match profiles and backups. It is not tied to a hardcoded serial number or Bluetooth address. Backups from a different mouse are rejected.

## Features

- Keyboard shortcuts and native Mouse4/Mouse5 actions for the 12 side buttons and left/right wheel tilt.
- Up to five DPI stages, from 100 to 30000 DPI.
- Per-application button and DPI profiles for macOS and Wine apps.
- Backups before writes, readback verification and restore.

When you click **Apply**, Naga saves **Default** button assignments marked **Stored on Mouse** to the mouse's onboard memory. They work with Naga closed. Assignments marked **Runs on Mac** and per-application button overrides are handled by Naga and require it to stay open. Battery status and macros are not implemented.

## Install

1. Download the DMG from [Releases](https://github.com/T410/razer-naga-v2-mac/releases).
2. Quit Naga, open the DMG and drag the app into **Applications**.
3. Open the app and follow its permission setup for Accessibility and Input Monitoring. Use **Complete Permissions** if access is missing.
4. Connect the receiver and turn on the mouse in 2.4 GHz mode.

Release DMGs are for **Apple Silicon (arm64)**. They use an ad-hoc signature and are not notarized. Replacing a development build may require granting permissions again. The app and installation instructions are in English; macOS permission dialogs follow the system language.

Naga installs no driver or system extension. It can run in the background at login; change this with **Start at Login** in its menu.

## Use

Select a control under **Button Assignments**, choose an action and click **Apply**. To record a shortcut, click the recording field and press the keys; Esc cancels. Accessibility access is needed to capture system shortcuts such as Control + Arrow.

Edit sensitivity under **DPI Stages**. The two top DPI buttons cycle through the applied stages. Use **Add Profile** to choose a macOS `.app` or Wine `.exe`, then customize its buttons or DPI settings. Wine profiles match the executable filename.

**Undo Change** discards the selected button's unapplied edit. The **Restore** menu restores settings from a backup. Profiles and backups stay in `~/Library/Application Support/Naga/` and are preserved when updating the app.

## Build and test

Use Xcode with a macOS 26 or later SDK. The Swift app has no external package dependencies.

```sh
zsh Scripts/build.sh
open "build/Razer NAGA v2.app"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Or open `Naga.xcodeproj`: **Naga** runs with the device; **Naga Preview** runs without hardware access or persistent profiles. Automated tests use simulated devices.

To create a local DMG, run `zsh Scripts/package-dmg.sh`. Pull requests run the tests and validate DMG packaging. After a merge to `main`, the [release workflow](.github/workflows/release-dmg.yml) chooses the next version, builds the app, pushes its version tag and publishes a GitHub release with the DMG and SHA-256 file.

For contribution setup and Angular commit rules, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Data and safety

Profiles, backups and diagnostic output can contain the mouse's serial number and application identifiers. They are local data and are not included in release assets. Raw hardware records, credentials and signing keys are excluded from Git.

The app does not write firmware or change device mode. Mouse memory writes are not atomic; power loss, disconnection or hardware failure can prevent recovery. See [SAFETY.md](SAFETY.md) for details and [hardware test notes](analysis/hardware) for earlier 2.4 GHz checks on one physical mouse.

## License

[MIT](LICENSE). Retain the copyright and license notice when redistributing the code. Protocol references are listed in [REFERENCES.md](REFERENCES.md).
