import AppKit

// The same native SF Symbol used by the menu bar, rendered at every macOS
// icon size. Run from the repository root: swift Scripts/generate-icon.swift
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap),
        let symbol = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 560, weight: size <= 64 ? .medium : .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.15, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1),
                              ending: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.38, alpha: 1))!
    gradient.draw(in: tile, angle: 90)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let scale = min(420 / symbol.size.width, 576 / symbol.size.height)
    let dimensions = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let mouseRect = NSRect(x: (1024 - dimensions.width) / 2, y: (1024 - dimensions.height) / 2 + 8,
                           width: dimensions.width, height: dimensions.height)
    let mouseShadow = NSShadow()
    mouseShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    mouseShadow.shadowBlurRadius = 10
    mouseShadow.shadowOffset = NSSize(width: 0, height: -5)
    mouseShadow.set()
    symbol.draw(in: mouseRect)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for size in [16, 32, 128, 256, 512] {
    try render(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.appendingPathComponent("AppIcon.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
print("Generated AppIcon.icns and AppIcon.png in \(output.path)")
