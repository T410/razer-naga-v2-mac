# References

The app's architecture, data model, interface and Swift implementation were written from scratch in this repository. Reference projects were not run, their drivers were not installed, and their code was not incorporated into the app. The following published protocol information was used.

- [NagaController](https://github.com/DParent10/NagaController): initial reference provided by the user for features and device behavior.
- [OpenNaga](https://github.com/Zer0codestuff/OpenNaga): physical control IDs, stored/active bank distinction, keyboard function byte format and macOS HID transport behavior. MIT-licensed reference.
- [OpenNaga OnboardProfilePlan](https://github.com/Zer0codestuff/OpenNaga/blob/main/Sources/NagaController/Hardware/OnboardProfilePlan.swift): Razer mouse function ordinal format for Mouse4 and Mouse5 (`01 01 04/05 00 00 00 00`), rather than USB report bitmasks. Read on November 10, 2026 for protocol information only; reference code was not executed.
- [OpenRazer razercommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c): 90-byte report format and XOR checksum.
- [OpenRazer razerchromacommon.c](https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c): DPI reading/writing and the 38-byte stage table.
- [OpenRazer razermouse_driver.c](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.c): transaction ID and receiver delay for the Naga V2 HyperSpeed.
- [OpenRazer issue 2845](https://github.com/openrazer/openrazer/issues/2845): button assignment protocol research.
- [Apple IOHIDDevice](https://developer.apple.com/documentation/iokit/iohiddevice_h): system HID access.
- [Apple CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent): sending shortcuts on the Mac.
- [Apple Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass): native controls and materials.
- [USB HID Usage Tables](https://www.usb.org/document-library/hid-usage-tables-16): physical keyboard usage IDs.

Initial reference date: November 9, 2026. Published protocol information alone does not establish that this app has been verified on a physical device.
