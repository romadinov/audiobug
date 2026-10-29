import AppKit
import CoreGraphics
// Draws the Audiobug icon in the Uberdoer style: a dark navy tile with a soft rim glow, three stacked,
// tilted blue→violet cards with extruded edges, and a glossy glowing cyan-green headphone on top.
// Usage: swift scripts/make-icon.swift <out.png> [size]
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let S = CGFloat(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.scaleBy(x: S / 1024, y: S / 1024)   // draw in 1024-pt coordinates, origin bottom-left
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// Background: deep navy with a faint radial lift and a soft blue rim.
let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
ctx.setFillColor(rgb(0.04, 0.07, 0.14)); ctx.fill(full)
ctx.saveGState()
ctx.drawRadialGradient(gradient([rgb(0.10, 0.16, 0.30), rgb(0.04, 0.07, 0.14, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 620, options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(full.insetBy(dx: 26, dy: 26), 200))
ctx.setStrokeColor(rgb(0.25, 0.45, 0.95, 0.35)); ctx.setLineWidth(6)
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0.25, 0.5, 1.0, 0.55))
ctx.strokePath()
ctx.restoreGState()

// Three stacked cards, tilted, fanning down-right (the back ones more violet).
struct Card { var dx: CGFloat; var dy: CGFloat; var top: CGColor; var bottom: CGColor; var edge: CGColor }
let cards = [
    Card(dx: 150, dy: -150, top: rgb(0.30, 0.30, 0.85), bottom: rgb(0.20, 0.16, 0.62), edge: rgb(0.12, 0.10, 0.40)),
    Card(dx: 75, dy: -75, top: rgb(0.22, 0.48, 0.96), bottom: rgb(0.18, 0.28, 0.80), edge: rgb(0.10, 0.16, 0.50)),
    Card(dx: 0, dy: 0, top: rgb(0.36, 0.72, 1.0), bottom: rgb(0.14, 0.40, 0.95), edge: rgb(0.08, 0.22, 0.62)),
]
let cardRect = CGRect(x: -300, y: -210, width: 600, height: 420)
let tilt: CGFloat = 7 * .pi / 180
for card in cards {
    ctx.saveGState()
    ctx.translateBy(x: 470 + card.dx, y: 560 + card.dy)
    ctx.rotate(by: tilt)
    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 50, color: rgb(0, 0, 0, 0.55))
    ctx.setFillColor(card.edge); ctx.addPath(rounded(cardRect.offsetBy(dx: 0, dy: -18), 70)); ctx.fillPath()
    ctx.restoreGState()
    // Extruded edge
    ctx.setFillColor(card.edge); ctx.addPath(rounded(cardRect.offsetBy(dx: 0, dy: -18), 70)); ctx.fillPath()
    // Face
    ctx.saveGState()
    ctx.addPath(rounded(cardRect, 70)); ctx.clip()
    ctx.drawLinearGradient(gradient([card.top, card.bottom], [0, 1]),
                           start: CGPoint(x: cardRect.minX, y: cardRect.maxY), end: CGPoint(x: cardRect.maxX, y: cardRect.minY), options: [])
    // Top-edge highlight
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.35), rgb(1, 1, 1, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: cardRect.maxY), end: CGPoint(x: 0, y: cardRect.maxY - 60), options: [])
    ctx.restoreGState()
    ctx.restoreGState()
}

// Headphone on the front card: band arc + two cups, glossy cyan→green with a glow.
func headphonePath() -> CGPath {
    let p = CGMutablePath()
    let c = CGPoint(x: 0, y: -20)
    let r: CGFloat = 150
    p.addArc(center: c, radius: r + 32, startAngle: .pi, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: c.x + r - 32, y: c.y))
    p.addArc(center: c, radius: r - 32, startAngle: 0, endAngle: .pi, clockwise: false)
    p.closeSubpath()
    for sx: CGFloat in [-1, 1] {
        let cup = CGRect(x: c.x + sx * r - 55, y: c.y - 140, width: 110, height: 150)
        p.addPath(rounded(cup, 40))
    }
    return p
}
ctx.saveGState()
ctx.translateBy(x: 470, y: 560)
ctx.rotate(by: tilt)
let shape = headphonePath()
// Glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0.2, 1.0, 0.9, 0.8))
ctx.setFillColor(rgb(0.3, 0.95, 0.9)); ctx.addPath(shape); ctx.fillPath()
ctx.restoreGState()
// Extrusion
ctx.saveGState()
ctx.translateBy(x: 0, y: -16)
ctx.setFillColor(rgb(0.05, 0.45, 0.55)); ctx.addPath(shape); ctx.fillPath()
ctx.restoreGState()
// Face gradient
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0.55, 1.0, 0.75), rgb(0.25, 0.9, 0.95), rgb(0.1, 0.6, 1.0)], [0, 0.5, 1]),
                       start: CGPoint(x: -200, y: 200), end: CGPoint(x: 200, y: -180), options: [])
// Specular sheen on the upper half
ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.65), rgb(1, 1, 1, 0.0)], [0, 1]),
                       start: CGPoint(x: 0, y: 170), end: CGPoint(x: 0, y: 40), options: [])
ctx.restoreGState()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
