// Regenerate the original CopyShelf icon with: swift scripts/icon.swift
import AppKit

let directory = URL(fileURLWithPath: "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.14, green: 0.28, blue: 0.64, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                     xRadius: 200, yRadius: 200).fill()
        NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 232, y: 310, width: 480, height: 490),
                     xRadius: 58, yRadius: 58).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 312, y: 240, width: 480, height: 490),
                     xRadius: 58, yRadius: 58).fill()
        NSColor(calibratedRed: 0.14, green: 0.28, blue: 0.64, alpha: 1).setFill()
        for y in [410, 520, 630] {
            NSBezierPath(roundedRect: NSRect(x: 390, y: y, width: 270, height: 32),
                         xRadius: 16, yRadius: 16).fill()
        }
        NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 220, y: 164, width: 584, height: 40),
                     xRadius: 20, yRadius: 20).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024 { try data.write(to: URL(fileURLWithPath: "assets/icon.png")) }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", "assets/AppIcon.icns"]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0)
