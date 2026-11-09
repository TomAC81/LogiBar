// Renders Resources/AppIcon.icns. Usage: swiftc Tools/make-icon.swift -o /tmp/mi && /tmp/mi <out-dir>
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, centered, continuous-corner squircle.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); path.fill()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    path.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.20, green: 0.35, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.18, blue: 0.72, alpha: 1)])!.draw(in: body, angle: -90)
    // Soft glass highlight on the top half
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)],
               atLocations: [0, 0.55], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    ctx.restoreGState()

    // Inner edge highlight
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.003, dy: s * 0.003), xRadius: radius, yRadius: radius)
    edge.lineWidth = s * 0.006
    NSColor.white.withAlphaComponent(0.35).setStroke(); edge.stroke()

    // Glyph
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        let r = CGRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        sym.draw(in: r)
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(out.path)
