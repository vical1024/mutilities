// Renders the app icon: cascading windows on a gradient tile.
// Usage: make-icon <output.icns>   (needs iconutil)
import AppKit

func render(_ side: Int) -> Data {
    let s = CGFloat(side)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Tile with the standard macOS margin.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor(red: 0.2, green: 0.25, blue: 0.7, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 1).cgColor,
                                       NSColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    // Three windows stacked down and to the right, back to front. Y grows upward here.
    let size = CGSize(width: 430, height: 340)
    for (index, alpha) in [(2, 0.45), (1, 0.7), (0, 1.0)].map({ ($0.0, $0.1) }) {
        let origin = CGPoint(x: 205 + CGFloat(2 - index) * 90, y: 432 - CGFloat(2 - index) * 90)
        let frame = CGRect(origin: CGPoint(x: origin.x, y: origin.y - size.height + 340 - 0), size: size)
        let path = CGPath(roundedRect: frame, cornerWidth: 38, cornerHeight: 38, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor); ctx.fillPath()
        ctx.restoreGState()
        // Title bar.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(NSColor(red: 0.12, green: 0.16, blue: 0.45, alpha: 0.22 * alpha).cgColor)
        ctx.fill(CGRect(x: frame.minX, y: frame.maxY - 72, width: frame.width, height: 72))
        ctx.restoreGState()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: frame.minX + 28 + CGFloat(i) * 36, y: frame.maxY - 50, width: 22, height: 22))
        }
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
