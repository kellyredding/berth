// Draws Berth's app icon, the template's and every site app's that sets no
// icon of its own: a window moored in a slip, ivory on a dark tile. Each size
// is drawn from the geometry rather than resampled, and the small sizes use
// heavier strokes so they stay legible at 16 px. Run by `make icon`:
//
//   swift Icon/berth-icon.swift <appiconset dir>

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: berth-icon.swift <appiconset dir>\n".data(using: .utf8)!)
    exit(2)
}
let directory = CommandLine.arguments[1]

// MARK: - Colour

struct Ink {
    let top: Int
    let bottom: Int
}

let bodyInk = Ink(top: 0x2E2E2C, bottom: 0x121211)
let ivory = Ink(top: 0xF6F2EA, bottom: 0xCBC3B3)

func color(_ value: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ ink: Ink) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(ink.top), color(ink.bottom)] as CFArray, locations: [0, 1]
    )!
}

// MARK: - The mark, in an 18-unit box with y down

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

/// A vertical two-stop gradient across the mark, clipped to the path.
func fill(_ cg: CGContext, _ path: CGPath, _ ink: Ink, alpha: CGFloat = 1, evenOdd: Bool = false) {
    cg.saveGState()
    cg.setAlpha(alpha)
    cg.addPath(path)
    if evenOdd { cg.clip(using: .evenOdd) } else { cg.clip() }
    cg.drawLinearGradient(gradient(ink), start: CGPoint(x: 0, y: 2), end: CGPoint(x: 0, y: 16), options: [])
    cg.restoreGState()
}

struct Weight {
    let frame: CGFloat
    let slip: CGFloat
    /// Nil leaves the water out, and centres the window and slip instead.
    let water: CGFloat?
    /// How far the window shrinks on each side, to clear the slip.
    var inset: CGFloat = 0

    func draw(_ cg: CGContext, _ ink: Ink) {
        if water == nil { cg.translateBy(x: 0, y: 1.3) }
        // The window: a frame with a solid title bar and a faint pane.
        let x = 4.6 + inset, y = 3.4 + inset, w = 8.8 - inset * 2, h = 7.2 - inset * 2, r: CGFloat = 1.4
        let outer = roundedRect(x, y, w, h, r)
        let inner = roundedRect(x + frame, y + frame, w - frame * 2, h - frame * 2, max(r - frame * 0.6, 0.4))
        let band = CGMutablePath()
        band.addPath(outer)
        band.addPath(inner)
        fill(cg, band, ink, evenOdd: true)
        fill(cg, inner, ink, alpha: 0.22)
        cg.saveGState()
        cg.addPath(outer)
        cg.clip()
        fill(cg, CGPath(rect: CGRect(x: x, y: y, width: w, height: 2.3), transform: nil), ink)
        cg.restoreGState()

        // The slip: a U the window rests in, open at the top.
        let slipPath = CGMutablePath()
        let left: CGFloat = 2.2, right: CGFloat = 15.8, top: CGFloat = 6.6, floor: CGFloat = 12.6, corner: CGFloat = 2.2
        slipPath.move(to: CGPoint(x: left, y: top))
        slipPath.addLine(to: CGPoint(x: left, y: floor - corner))
        slipPath.addArc(tangent1End: CGPoint(x: left, y: floor), tangent2End: CGPoint(x: left + corner, y: floor), radius: corner)
        slipPath.addLine(to: CGPoint(x: right - corner, y: floor))
        slipPath.addArc(tangent1End: CGPoint(x: right, y: floor), tangent2End: CGPoint(x: right, y: floor - corner), radius: corner)
        slipPath.addLine(to: CGPoint(x: right, y: top))
        fill(cg, slipPath.copy(strokingWithWidth: slip, lineCap: .round, lineJoin: .round, miterLimit: 10), ink)

        // The water below it: one gentle wave.
        guard let water else { return }
        let wave = CGMutablePath()
        let waveY: CGFloat = 15.2, amplitude: CGFloat = 0.55
        wave.move(to: CGPoint(x: 3.6, y: waveY))
        var start: CGFloat = 3.6
        for index in 0..<4 {
            let end = start + 2.7
            let control = index % 2 == 0 ? waveY - amplitude * 2 : waveY + amplitude * 2
            wave.addQuadCurve(to: CGPoint(x: end, y: waveY), control: CGPoint(x: (start + end) / 2, y: control))
            start = end
        }
        fill(cg, wave.copy(strokingWithWidth: water, lineCap: .round, lineJoin: .round, miterLimit: 10), ink, alpha: 0.7)
    }
}

let regular = Weight(frame: 1.15, slip: 1.35, water: 0.9)
let heavy = Weight(frame: 1.4, slip: 1.6, water: 1.2, inset: 0.5)
let tiny = Weight(frame: 1.4, slip: 1.5, water: nil, inset: 0.9)

// MARK: - The body: an 824-point superellipse (exponent 5) on a 1024 canvas

func body() -> CGPath {
    let path = CGMutablePath()
    let half: CGFloat = 412
    let exponent: CGFloat = 5
    for step in 0...720 {
        let angle = CGFloat(step) / 720 * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let point = CGPoint(
            x: 512 + half * copysign(pow(abs(c), 2 / exponent), c),
            y: 512 + half * copysign(pow(abs(s), 2 / exponent), s)
        )
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// The mark's 18-unit box spans 640 of the 1024 canvas, centred.
let unit: CGFloat = 640 / 18

func draw(_ cg: CGContext, size: Int) {
    // Shadows are measured in the bitmap's pixels, y up, whatever the
    // transform, so they are scaled by hand.
    let factor = CGFloat(size) / 1024

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * factor), blur: 24 * factor, color: color(0x000000, alpha: 0.35))
    cg.addPath(body())
    cg.setFillColor(color(bodyInk.bottom))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(body())
    cg.clip()
    cg.drawLinearGradient(gradient(bodyInk), start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    cg.restoreGState()

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8 * factor), blur: 18 * factor, color: color(0x000000, alpha: 0.55))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.translateBy(x: 512 - 9 * unit, y: 512 - 9 * unit)
    cg.scaleBy(x: unit, y: unit)
    (size <= 16 ? tiny : size <= 32 ? heavy : regular).draw(cg, ivory)
    cg.endTransparencyLayer()
    cg.restoreGState()
}

func render(size: Int) -> Data {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let factor = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: factor, y: -factor)
    draw(context, size: size)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size).write(to: URL(fileURLWithPath: "\(directory)/icon_\(size).png"))
}
