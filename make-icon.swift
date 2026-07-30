// Renders AppIcon.iconset + AppIcon.icns for petze.
// Usage: swift make-icon.swift && iconutil -c icns AppIcon.iconset
import AppKit

let master = 1024

func drawIcon(canvas: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: canvas, height: canvas))
    img.lockFocus()

    // macOS-style squircle with standard margins (~10% each side)
    let margin = canvas * 0.098
    let rect = NSRect(x: margin, y: margin,
                      width: canvas - 2 * margin, height: canvas - 2 * margin)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: rect.width * 0.225,
                                yRadius: rect.width * 0.225)

    // soft drop shadow like system icons
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.008)
    shadow.shadowBlurRadius = canvas * 0.02
    shadow.set()

    // dark "screen" background
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.045, green: 0.06, blue: 0.085, alpha: 1),
    ])!.draw(in: squircle, angle: -70)
    NSGraphicsContext.current?.restoreGraphicsState()

    squircle.setClip()

    // the product: health lines hugging the top edge, stacked inward
    let lineHeight = rect.height * 0.075
    let gap = lineHeight * 0.55
    let lines: [(width: CGFloat, color: NSColor)] = [
        (0.86, NSColor(calibratedRed: 0.0, green: 0.86, blue: 0.50, alpha: 1)),  // green
        (0.42, NSColor(calibratedRed: 0.96, green: 0.77, blue: 0.09, alpha: 1)), // yellow
        (0.62, NSColor(calibratedRed: 0.19, green: 0.69, blue: 0.78, alpha: 1)), // teal
    ]
    var y = rect.maxY - rect.height * 0.13 - lineHeight
    for line in lines {
        let bar = NSRect(x: rect.minX, y: y,
                         width: rect.width * line.width, height: lineHeight)
        line.color.setFill()
        NSBezierPath(roundedRect: bar,
                     xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        // subtle glow
        line.color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bar.insetBy(dx: -lineHeight * 0.35,
                                              dy: -lineHeight * 0.35),
                     xRadius: lineHeight, yRadius: lineHeight).fill()
        y -= lineHeight + gap
    }

    // faint bottom hint of a desktop horizon
    let horizon = NSRect(x: rect.minX, y: rect.minY,
                         width: rect.width, height: rect.height * 0.30)
    NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.06),
        NSColor(calibratedWhite: 1.0, alpha: 0.0),
    ])!.draw(in: horizon, angle: 90)

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let icon = drawIcon(canvas: CGFloat(master))
let dir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(icon, size: base, to: "\(dir)/icon_\(base)x\(base).png")
    writePNG(icon, size: base * 2, to: "\(dir)/icon_\(base)x\(base)@2x.png")
}
writePNG(icon, size: 256, to: "docs/icon.png")
print("iconset written")
