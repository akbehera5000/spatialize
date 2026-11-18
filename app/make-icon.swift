// Renders the app icon (1024 px PNG): AirPods Pro glyph on a deep blue-violet squircle with
// concentric "sound field" rings. usage: swift make-icon.swift OUT.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// shadow + body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.22, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()

squircle.addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.46, green: 0.22, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.06, blue: 0.30, alpha: 1),
])!
grad.draw(in: rect, angle: -60)

// sound-field rings
let center = CGPoint(x: size / 2, y: size / 2 - 10)
for (i, r) in [150.0, 235.0, 320.0, 405.0].enumerated() {
    let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r * 0.62, width: 2 * r, height: 2 * r * 0.62))
    ring.lineWidth = 10
    NSColor.white.withAlphaComponent(0.20 - Double(i) * 0.04).setStroke()
    ring.stroke()
}

// glass sheen
let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
sheen.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

// glyph
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = sym.size
    sym.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2 + 10, width: s.width, height: s.height))
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
