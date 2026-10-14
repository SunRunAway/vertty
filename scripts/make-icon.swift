// Renders the iconset for Resources/AppIcon.icns. A knock-off of Ghostty's icon
// (metal bezel, blue CRT screen, glowing ghost) with the ghosts stacked as a
// vertical tab strip and the ">_" prompt turned on its side into "v|".
// Also renders the iOS app's icon (iOS/Vhostty/Assets.xcassets): the same
// picture with the bezel filling the square, since iOS rounds the corners.
// Run: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon . &&
//      iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r, green: g, blue: b, alpha: a)
}

/// Ghost outline in a w×h box at `o`: rounded head, straight sides, three
/// scallops along the bottom.
func ghostPath(_ o: NSPoint, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let r = w * 0.48, wave = h * 0.08
    p.move(to: NSPoint(x: o.x, y: o.y + wave))
    p.line(to: NSPoint(x: o.x, y: o.y + h - r))
    p.appendArc(withCenter: NSPoint(x: o.x + w / 2, y: o.y + h - r), radius: w / 2, startAngle: 180, endAngle: 0, clockwise: true)
    p.line(to: NSPoint(x: o.x + w, y: o.y + wave))
    let step = w / 3
    for i in 0..<3 {
        let x1 = o.x + w - CGFloat(i) * step, x0 = x1 - step
        p.curve(to: NSPoint(x: x0, y: o.y + wave),
                controlPoint1: NSPoint(x: x1 - step * 0.1, y: o.y - wave),
                controlPoint2: NSPoint(x: x0 + step * 0.1, y: o.y - wave))
    }
    p.close()
    return p
}

func drawGhost(_ o: NSPoint, _ w: CGFloat, _ h: CGFloat, selected: Bool) {
    let body = ghostPath(o, w, h)
    NSGraphicsContext.saveGraphicsState()
    if selected {
        let glow = NSShadow()
        glow.shadowColor = rgb(0.55, 0.75, 1, 0.9)
        glow.shadowBlurRadius = w * 0.35
        glow.set()
    }
    rgb(0.80, 0.88, 1, selected ? 0.95 : 0.30).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    body.lineWidth = w * 0.045
    rgb(1, 1, 1, selected ? 1 : 0.35).setStroke()
    body.stroke()

    // Face: "v" (the ">" turned 90°) and a "|" cursor (the "_" turned 90°).
    let face = NSBezierPath()
    let cy = o.y + h * 0.58
    face.move(to: NSPoint(x: o.x + w * 0.20, y: cy + h * 0.08))
    face.line(to: NSPoint(x: o.x + w * 0.34, y: cy - h * 0.07))
    face.line(to: NSPoint(x: o.x + w * 0.48, y: cy + h * 0.08))
    face.move(to: NSPoint(x: o.x + w * 0.70, y: cy + h * 0.09))
    face.line(to: NSPoint(x: o.x + w * 0.70, y: cy - h * 0.09))
    face.lineWidth = w * 0.09
    face.lineCapStyle = .round
    face.lineJoinStyle = .round
    rgb(0.04, 0.07, 0.35, selected ? 1 : 0.5).setStroke()
    face.stroke()
}

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size

    // Metal bezel
    let outer = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bezel = NSBezierPath(roundedRect: outer, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = rgb(0, 0, 0, 0.35)
    drop.shadowBlurRadius = s * 0.015
    drop.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    drop.set()
    rgb(0.6, 0.6, 0.62).setFill()
    bezel.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(0.93, 0.93, 0.95), rgb(0.62, 0.62, 0.65), rgb(0.80, 0.80, 0.83)])!
        .draw(in: bezel, angle: -90)

    // Black frame
    let frameRect = outer.insetBy(dx: s * 0.035, dy: s * 0.035)
    rgb(0.04, 0.04, 0.05).setFill()
    NSBezierPath(roundedRect: frameRect, xRadius: s * 0.15, yRadius: s * 0.15).fill()

    // Blue CRT screen
    let screen = frameRect.insetBy(dx: s * 0.03, dy: s * 0.03)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.1, yRadius: s * 0.1)
    NSGraphicsContext.saveGraphicsState()
    screenPath.addClip()
    NSGradient(colors: [rgb(0.10, 0.18, 0.95), rgb(0.03, 0.07, 0.62), rgb(0.01, 0.03, 0.35)])!
        .draw(in: screenPath, relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))

    // Phosphor dot grid (skipped where it would just blur into the gradient)
    let pitch = s * 0.0125
    if pitch >= 3 {
        rgb(0.55, 0.65, 1, 0.3).setFill()
        let dot = s * 0.003
        var y = screen.minY + pitch / 2
        while y < screen.maxY {
            var x = screen.minX + pitch / 2
            while x < screen.maxX {
                NSBezierPath(ovalIn: NSRect(x: x - dot, y: y - dot, width: 2 * dot, height: 2 * dot)).fill()
                x += pitch
            }
            y += pitch
        }
    }

    // Sidebar divider
    let tabW = screen.width * 0.2, tabH = tabW * 1.1
    let colX = screen.minX + screen.width * 0.09
    let divX = colX + tabW + screen.width * 0.08
    rgb(0.6, 0.75, 1, 0.35).setFill()
    NSRect(x: divX, y: screen.minY + screen.height * 0.06, width: max(1, s * 0.004), height: screen.height * 0.88).fill()

    // Ghost tabs, top one selected
    let gap = screen.height * 0.07
    let top = screen.midY + (3 * tabH + 2 * gap) / 2 - tabH
    for i in (0..<3).reversed() {
        drawGhost(NSPoint(x: colX, y: top - CGFloat(i) * (tabH + gap)), tabW, tabH, selected: i == 0)
    }

    // Glass reflection across the top-right
    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: screen.minX + screen.width * 0.35, y: screen.maxY))
    gloss.line(to: NSPoint(x: screen.maxX, y: screen.maxY))
    gloss.line(to: NSPoint(x: screen.maxX, y: screen.minY + screen.height * 0.45))
    gloss.close()
    NSGradient(colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0.02)])!.draw(in: gloss, angle: -45)
    NSGraphicsContext.restoreGraphicsState()

    // Inner bevel highlight on the screen edge
    screenPath.lineWidth = s * 0.004
    rgb(1, 1, 1, 0.12).setStroke()
    screenPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The iOS icon: opaque, the bezel (the middle 80% of the Mac icon) filling
/// the square.
func renderIOS(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSGradient(colors: [rgb(0.93, 0.93, 0.95), rgb(0.62, 0.62, 0.65), rgb(0.80, 0.80, 0.83)])!
        .draw(in: bounds, angle: -90)
    let mac = NSImage(size: NSSize(width: size * 1.25, height: size * 1.25))
    mac.addRepresentation(render(size * 1.25))
    mac.draw(in: NSRect(x: -size * 0.125, y: -size * 0.125, width: size * 1.25, height: size * 1.25))
    NSGraphicsContext.restoreGraphicsState()
    // Without an alpha channel, as App Store icons must be.
    let opaque = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    opaque.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: opaque.makeImage()!)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)

let iosIcon = root.appendingPathComponent("iOS/Vhostty/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: iosIcon, withIntermediateDirectories: true)
try! renderIOS(1024).representation(using: .png, properties: [:])!
    .write(to: iosIcon.appendingPathComponent("icon-1024.png"))
print(iosIcon.path)
