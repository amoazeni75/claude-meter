#!/usr/bin/env swift
//
// Generates AppIcon.iconset from code, so the repo carries a drawing rather
// than a binary blob. build.sh runs this and pipes the result to iconutil.
//
//   swift Tools/make-icon.swift <output.iconset>
//
// The dial is a gauge whose coloured bands are the app's real thresholds —
// 0–50 green, 50–75 yellow, 75–90 orange, 90–100 red — laid over 240°, so the
// green arc is genuinely half the sweep and the red one a tenth of it.

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.iconset"

let space = CGColorSpaceCreateDeviceRGB()

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let sweepStart: CGFloat = 210   // upper-left
let sweepTotal: CGFloat = 240   // down through the bottom to upper-right
let needleValue: CGFloat = 76   // parked in the orange band

/// value 0–100 -> angle on the dial
func angle(for value: CGFloat) -> CGFloat {
    deg(sweepStart - (value / 100) * sweepTotal)
}

func draw(size S: CGFloat, ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Plate ------------------------------------------------------------------
    let inset = S * 0.055
    let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let corner = plate.width * 0.2237     // macOS squircle, near enough
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner,
                           cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [rgba(0.17, 0.18, 0.22), rgba(0.07, 0.07, 0.09)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])
    ctx.restoreGState()

    // Faint rim so the plate keeps an edge on a dark desktop.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.setStrokeColor(rgba(1, 1, 1, 0.12))
    ctx.setLineWidth(max(1, S * 0.005))
    ctx.strokePath()
    ctx.restoreGState()

    // Dial -------------------------------------------------------------------
    let center = CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.055)
    let radius = plate.width * 0.305
    let track = plate.width * 0.135

    // Unlit track underneath, so the dial still reads as a ring.
    ctx.setLineCap(.butt)
    ctx.setLineWidth(track)
    ctx.setStrokeColor(rgba(1, 1, 1, 0.07))
    ctx.addArc(center: center, radius: radius,
               startAngle: angle(for: 0), endAngle: angle(for: 100), clockwise: true)
    ctx.strokePath()

    let bands: [(CGFloat, CGFloat, CGColor)] = [
        (0,  50,  rgba(0.30, 0.78, 0.35)),   // green
        (50, 75,  rgba(0.98, 0.80, 0.10)),   // yellow
        (75, 90,  rgba(0.98, 0.55, 0.10)),   // orange
        (90, 100, rgba(0.94, 0.27, 0.24)),   // red
    ]
    // A hairline gap between bands keeps them distinct when the icon is 16px.
    let gap: CGFloat = S >= 64 ? 1.6 : 0.9
    for (from, to, color) in bands {
        ctx.setStrokeColor(color)
        ctx.addArc(center: center, radius: radius,
                   startAngle: angle(for: from) - deg(from == 0 ? 0 : gap),
                   endAngle: angle(for: to),
                   clockwise: true)
        ctx.strokePath()
    }

    // Needle -----------------------------------------------------------------
    let a = angle(for: needleValue)
    let tip = CGPoint(x: center.x + cos(a) * radius * 0.80,
                      y: center.y + sin(a) * radius * 0.80)
    let tail = CGPoint(x: center.x - cos(a) * radius * 0.20,
                       y: center.y - sin(a) * radius * 0.20)

    ctx.setLineCap(.round)
    ctx.setLineWidth(max(1.2, S * 0.042))
    ctx.setStrokeColor(rgba(0.05, 0.05, 0.06, 0.55))   // seat it against the dial
    ctx.move(to: tail); ctx.addLine(to: tip); ctx.strokePath()

    ctx.setLineWidth(max(1, S * 0.030))
    ctx.setStrokeColor(rgba(1, 1, 1, 0.97))
    ctx.move(to: tail); ctx.addLine(to: tip); ctx.strokePath()

    let hub = S * 0.052
    ctx.setFillColor(rgba(1, 1, 1))
    ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub,
                               width: hub * 2, height: hub * 2))
    ctx.setFillColor(rgba(0.10, 0.10, 0.13))
    let inner = hub * 0.42
    ctx.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                               width: inner * 2, height: inner * 2))
}

func writePNG(pixels: Int, to path: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    guard let g = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
    NSGraphicsContext.current = g
    draw(size: CGFloat(pixels), ctx: g.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    do { try data.write(to: URL(fileURLWithPath: path)) }
    catch { fatalError("write failed: \(error)") }
}

// The exact set iconutil expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),      ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),      ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),   ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),   ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),   ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)
for v in variants {
    writePNG(pixels: v.pixels, to: (outDir as NSString).appendingPathComponent(v.name))
}
print("wrote \(variants.count) sizes to \(outDir)")
