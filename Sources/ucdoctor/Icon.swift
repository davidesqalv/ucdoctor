import AppKit

// The app icon: a white clipboard with a heartbeat line on a blue squircle.
// Drawn from plain paths (SF Symbols aren't licensed for use in app icons).

/// Writes every size `iconutil` needs into an .iconset folder.
func makeIconSet(at dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try renderIcon(pixels: base * scale).write(to: dir.appendingPathComponent(name))
        }
    }
}

private func renderIcon(pixels px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Background: Apple's icon grid puts the body at ~80% of the canvas, leaving room for the shadow.
    let body = NSRect(x: s * 0.1, y: s * 0.09, width: s * 0.8, height: s * 0.8)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    withShadow(blur: s * 0.025, offset: -s * 0.012, alpha: 0.28) {
        NSColor(srgbRed: 0.08, green: 0.40, blue: 0.90, alpha: 1).setFill()
        squircle.fill()
    }
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.68, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.34, blue: 0.86, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    // Clipboard board.
    let board = NSRect(x: s * 0.29, y: s * 0.20, width: s * 0.42, height: s * 0.52)
    withShadow(blur: s * 0.02, offset: -s * 0.008, alpha: 0.25) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: board, xRadius: s * 0.045, yRadius: s * 0.045).fill()
    }

    // Clip at the top, overlapping the board's edge.
    let clip = NSRect(x: s * 0.39, y: board.maxY - s * 0.045, width: s * 0.22, height: s * 0.09)
    NSColor(srgbRed: 0.80, green: 0.88, blue: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: clip, xRadius: s * 0.03, yRadius: s * 0.03).fill()
    NSColor(srgbRed: 0.05, green: 0.34, blue: 0.86, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.48, y: clip.midY - s * 0.012, width: s * 0.04, height: s * 0.024)).fill()

    // Heartbeat across the board.
    let y = board.midY - s * 0.02
    let x0 = board.minX + s * 0.05, w = board.width - s * 0.10
    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: x0, y: y))
    for (fx, fy) in [(0.30, 0.0), (0.40, 0.10), (0.52, -0.12), (0.62, 0.05), (0.70, 0.0), (1.0, 0.0)] {
        pulse.line(to: NSPoint(x: x0 + w * fx, y: y + s * fy))
    }
    pulse.lineWidth = max(1, s * 0.035)
    pulse.lineJoinStyle = .round
    pulse.lineCapStyle = .round
    NSColor(srgbRed: 0.07, green: 0.42, blue: 0.92, alpha: 1).setStroke()
    pulse.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

private func withShadow(blur: CGFloat, offset: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offset)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}
