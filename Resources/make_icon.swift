// Draws the app icon and writes Resources/AppIcon.icns.  Run:  swift Resources/make_icon.swift
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.36, blue: 0.33, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.22, blue: 0.24, alpha: 1)])!.draw(in: path, angle: -90)

    // A ledger: a header rule, three account rows, and a double-underlined total.
    let ink = NSColor.white
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ alpha: CGFloat) {
        ink.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s), xRadius: h * s / 2, yRadius: h * s / 2).fill()
    }
    let rows: [(CGFloat, CGFloat, CGFloat)] = [(690, 300, 190), (590, 240, 150), (490, 330, 210)]
    for (y, nameWidth, amountWidth) in rows {
        bar(230, y, nameWidth, 44, 0.55)
        bar(794 - amountWidth, y, amountWidth, 44, 0.95)
    }
    bar(230, 400, 564, 12, 0.5)
    bar(230, 300, 200, 52, 0.55)
    bar(794 - 250, 300, 250, 52, 1)
    bar(794 - 250, 262, 250, 10, 0.9)
    bar(794 - 250, 240, 250, 10, 0.9)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let png = draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote AppIcon.icns" : "iconutil failed")
