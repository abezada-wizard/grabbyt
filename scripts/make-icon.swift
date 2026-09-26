// Genera AppIcon.icns: conejo sobre un degradado. Uso: swift scripts/make-icon.swift <salida.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Grabbyt.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 1), NSColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1)])!
        .draw(in: path, angle: -60)
    let emoji = "🐇" as NSString
    let font = NSFont.systemFont(ofSize: rect.width * 0.62)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let size = emoji.size(withAttributes: attrs)
    emoji.draw(at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.02), withAttributes: attrs)
    // Flecha de descarga en la esquina
    let arrow = "⬇︎" as NSString
    let aAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: rect.width * 0.2), .foregroundColor: NSColor.white]
    arrow.draw(at: NSPoint(x: rect.maxX - rect.width * 0.28, y: rect.minY + rect.width * 0.04), withAttributes: aAttrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
print("Icono: \(out)")
