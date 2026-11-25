# Synapse signatures and the HID write path

Analysis date: November 9, 2026. Method: static analysis of installed files, decompilation with REA/Ghidra and safe extraction of ASAR contents. Synapse, its helper services and extracted Node modules were not executed. No mouse read/write commands were sent; drivers, permissions and app files were unchanged.

## Findings

No Synapse-specific cryptographic signature, secret key or challenge-response step was observed in the inspected general USB HID sending path. The 90-byte settings payload is packaged with a HID report ID and passed to the macOS `IOHIDDeviceSetReport` API.

A Razer code-signature check was found for validating Synapse software files. It checks file paths, the Apple certificate chain and the Razer Team ID. It is not inside the inspected HID sending function.

This is not proof that every Naga V2 HyperSpeed firmware command or every authentication mechanism in other models lacks such checks. Physical settings writes with our app had not yet been tested at the time of this analysis.

## Inspected installation

| Component | Identity |
|---|---|
| Razer Synapse launcher | `com.razer.synapse`, version `0.8.11` |
| Razer AppEngine | `com.razer.appengine.app`, version `4.4.25`, build `4.4.25.194` |
| Synapse executable SHA-256 | `70fe8c3cb17b05ab4e015a615b3e1526fcd55ac11dadc2002eb005090069bee9` |
| `libsimple_service.dylib` SHA-256 | `178b95c9b20b5f913aff9adcc46c814e9b51d22a392dfaabf8bfc718f64be907` |
| AppEngine `app.asar` SHA-256 | `9b07b3318a5756a6ebf45dcab0c419b2c2bab312f17a953801e2dcbbaf7a9751` |
| Extracted `node-rz-hid/build/Release/HID.node` SHA-256 | `c08f9574e0a41522840be240637a90a5b21cb0618e4fa7dacd1ae4e4d7c0304b` |

## Observed software signature check

The launcher's macOS signature identifies Razer USA Ltd. as the developer, with Team ID `R2H967U7J8`. This identifies the installed software's code signature; it was not observed as a signature sent to the mouse.

Two functions in `libsimple_service.dylib` were inspected:

- `simple_service::CheckSignature`, address `0x53f50`: contains paths that validate the bundle signature and, where needed, the code signature. The Razer Team ID constant is used here.
- `simple_service::CheckSignatureWithCodeSign`, address `0x536e0`: creates a CFURL and static code object from a file path, constructs a certificate requirement with Apple Security APIs and calls `SecStaticCodeCheckValidityWithErrors`.

Callers of `CheckSignature` include `InstallAppElevatedOnIOThread`, `LaunchProcessOnIOThread`, `LaunchRazerAppOnIOThread` and `CheckAndCopyUserAppFile`. These are static call relationships, not runtime observations.

Full record: `service-evidence.json`. These are static Ghidra observations; decompiler output is not presented as original source code.

## Observed USB HID sending path

The ASAR file `electron/UsbRzDeviceAction.js` contains `hid.sendFeatureReport` / `hid.sendFeatureReportMutex` branches. The inspected branch:

1. Selects a device from the current device map.
2. Acquires a mutex if requested.
3. If `dataSend` is 90 bytes, prepends a report ID to create a 91-byte Node-HID input.
4. Passes the data to `hidDevice.sendFeatureReport`.

No cryptographic signature generation or token insertion was observed in this branch. This finding does not extend to all higher layers or to device-specific interpretation of received data.

`node-rz-hid/nodehid.js` loads the native `HID.node` binding. The compiled binding's `hid_send_feature_report` function, address `0x128d0`, was also inspected with Ghidra. Its complete function body:

- Checks for an empty device and disconnection.
- Skips Node-HID's extra ID byte when the report ID is zero.
- Calls `IOHIDDeviceSetReport` directly with feature report type `2`.
- Returns the result code.

No Razer signature, account token, nonce or HMAC check or generation was found inside this compiled function. Operating system HID permissions were not disabled or bypassed during this analysis.

The same package's `hidapi/mac/hid.c` source contains a matching flow in `set_report` (lines 907–943) and `hid_send_feature_report` (lines 1129–1132). The presence of source alone was not taken as proof of binary equivalence; the compiled function was separately inspected.

Content hashes:

- JS sender SHA-256: `9e6468306c1e93b93a02fa380b42da81f3d1e2b9ee29cdd10a2ceeab6e569f2c`; inspected UTF-8 byte range `[6375, 7768)`.
- `hidapi/mac/hid.c` SHA-256: `55d981f54bfed4eecaf6bfcbec8bd701db465457f6f60317cae3a9922393629c`.
- `nodehid.js` SHA-256: `26eab941a2aeb5aacd54e03a3a919c265e14bf389356bb572b32ec1d11543031`.

## Implications for this app

Naga also uses existing macOS HID APIs; it does not go through Razer's app launch or installation service. Nothing in the inspected path indicates that it needs to imitate the Razer Team ID check.

The XOR checksum in our settings packets is a data integrity field, not a cryptographic sender identity. This packet format matches the published [OpenRazer report format](https://github.com/openrazer/openrazer/blob/master/driver/razercommon.h) and [checksum code](https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c).

An independent supporting example is [OpenNaga](https://github.com/Zer0codestuff/OpenNaga#readme), which documents writing persistent assignments and DPI through the USB receiver for the same Naga V2 HyperSpeed model. This project does not replace hardware testing of our own app.

## Limits

- The inspected Mac Synapse installation does not offer model-specific settings for the Naga V2 HyperSpeed. Observations of a common sender cannot be generalized to all device firmware.
- Not every ASAR file was semantically inspected. The initial REA JavaScript analysis selected only `package.json`; the USB branch and HID sources were later read statically from extracted files.
- Complete Razer account/session authentication, firmware update protocols and Bluetooth protocols were not analyzed.
- No traffic was captured from a running Synapse process. Device firmware was not decompiled.
- Our write code passed simulated-device tests; this analysis did not include writing settings to the physical mouse.

The local REA analysis sessions were closed. Product source code was unchanged during the analysis. Large raw evidence JSON files remain in the working directory and are excluded by Git ignore rules.
