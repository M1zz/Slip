#!/usr/bin/env swift
//
// Generates the app icon master PNG (1024×1024) for Slip.
//
// Design: a central paper slip surrounded by three satellite slips
// connected to it (and to each other) by thin lines — a tiny graph
// constellation of notes. This reads more like what Slip actually
// does than the previous "stack of paper" icon: the slips are the
// Zettelkasten unit, and the lines are the wikilinks / backlinks
// that turn them into a knowledge network. Background is the same
// indigo → deep-purple squircle so the brand stays consistent.
//
// Run from the project root:
//
//     swift tools/generate_icon.swift
//
// The script emits AppIcon-1024.png next to itself; the surrounding
// shell script in tools/generate_icons.sh then sips it down into the
// asset-catalog sizes.

import AppKit
import CoreGraphics

let masterSize: CGFloat = 1024
let imageSize = NSSize(width: masterSize, height: masterSize)
let image = NSImage(size: imageSize)

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// MARK: - Background

let bgRect = NSRect(x: 0, y: 0, width: masterSize, height: masterSize)
let cornerRadius = masterSize * 0.225
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

let bgGradient = NSGradient(colors: [
    NSColor(srgbRed: 0.46, green: 0.34, blue: 0.88, alpha: 1.0),  // top — indigo
    NSColor(srgbRed: 0.27, green: 0.18, blue: 0.62, alpha: 1.0)   // bottom — deep purple
])!

ctx.saveGState()
bgPath.addClip()
bgGradient.draw(in: bgRect, angle: -90)
ctx.restoreGState()

// MARK: - Layout: a central slip + three satellites

let center = CGPoint(x: masterSize / 2, y: masterSize / 2)

// Each satellite is described by an angle (around the center) and a
// rotation so the cards feel hand-tossed instead of stamped.
struct Satellite {
    let angle: CGFloat       // direction from center, in degrees (0 = right, 90 = up)
    let distance: CGFloat    // distance from icon center, in px
    let rotation: CGFloat    // card tilt, in degrees
}
let satellites: [Satellite] = [
    Satellite(angle: 138, distance: 380, rotation:  -16),  // upper-left
    Satellite(angle:  42, distance: 380, rotation:   12),  // upper-right
    Satellite(angle: 270, distance: 360, rotation:   -4),  // bottom
]

func point(angleDeg: CGFloat, distance: CGFloat) -> CGPoint {
    let r = angleDeg * .pi / 180
    return CGPoint(x: center.x + cos(r) * distance,
                   y: center.y + sin(r) * distance)
}

// MARK: - Connecting lines (drawn first, so the slips sit on top)

ctx.saveGState()
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
ctx.setLineWidth(10)
ctx.setLineCap(.round)

let satellitePoints = satellites.map { point(angleDeg: $0.angle, distance: $0.distance) }

// Center → each satellite. These are the "this note links to that
// note" edges that the graph view draws.
for p in satellitePoints {
    ctx.move(to: center)
    ctx.addLine(to: p)
}
// Edges between every pair of satellites — the cluster reads as a
// small connected graph instead of a hub-and-spoke star, which would
// imply a single root note. Slip's graph is peer-to-peer.
for i in 0..<satellitePoints.count {
    for j in (i + 1)..<satellitePoints.count {
        ctx.move(to: satellitePoints[i])
        ctx.addLine(to: satellitePoints[j])
    }
}
ctx.strokePath()
ctx.restoreGState()

// MARK: - Connector dots at each endpoint

func drawDot(at p: CGPoint, radius: CGFloat) {
    let r = NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
    NSColor.white.withAlphaComponent(0.8).setFill()
    NSBezierPath(ovalIn: r).fill()
}
for p in satellitePoints {
    drawDot(at: p, radius: 14)
}
drawDot(at: center, radius: 18)

// MARK: - Slip cards

let mainPaperWidth: CGFloat = masterSize * 0.34
let mainPaperHeight: CGFloat = masterSize * 0.42
let satellitePaperWidth: CGFloat = masterSize * 0.17
let satellitePaperHeight: CGFloat = masterSize * 0.20

func drawSlip(
    at point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    rotationDeg: CGFloat,
    cornerRadius: CGFloat,
    alpha: CGFloat
) -> CGRect {
    ctx.saveGState()
    ctx.translateBy(x: point.x, y: point.y)
    ctx.rotate(by: rotationDeg * .pi / 180)

    let r = NSRect(
        x: -width / 2, y: -height / 2, width: width, height: height
    )
    let path = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowBlurRadius = 22
    shadow.set()

    NSColor(srgbRed: 0.992, green: 0.984, blue: 0.965, alpha: alpha).setFill()
    path.fill()
    NSShadow().set()

    ctx.restoreGState()
    return r
}

// Satellites first, so the central slip sits in front of them.
for s in satellites {
    let p = point(angleDeg: s.angle, distance: s.distance)
    _ = drawSlip(
        at: p,
        width: satellitePaperWidth,
        height: satellitePaperHeight,
        rotationDeg: s.rotation,
        cornerRadius: 22,
        alpha: 0.94
    )
}

// Central slip — the focused note.
_ = drawSlip(
    at: center,
    width: mainPaperWidth,
    height: mainPaperHeight,
    rotationDeg: -3,
    cornerRadius: 32,
    alpha: 1.0
)

// MARK: - Text strokes on the central slip

ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: -3 * .pi / 180)

let strokeColor = NSColor(srgbRed: 0.43, green: 0.32, blue: 0.85, alpha: 0.55)
strokeColor.setFill()

let strokeHeight: CGFloat = 22
let strokeGap: CGFloat = 56
let strokeStartX = -mainPaperWidth / 2 + 48

// Three lines: a longer "title", then two shorter body lines, so
// the silhouette still reads as "a note" at small sizes where the
// connection lines might not all be discernible.
let lineLengths: [CGFloat] = [0.78, 0.62, 0.40]
for (i, frac) in lineLengths.enumerated() {
    let y: CGFloat = 50 - CGFloat(i) * strokeGap
    let w = (mainPaperWidth - 96) * frac
    let r = NSRect(x: strokeStartX, y: y, width: w, height: strokeHeight)
    let p = NSBezierPath(roundedRect: r, xRadius: strokeHeight / 2, yRadius: strokeHeight / 2)
    p.fill()
}

ctx.restoreGState()

image.unlockFocus()

// MARK: - Save

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let outURL = outDir.appendingPathComponent("AppIcon-1024.png")
try png.write(to: outURL)
print("wrote \(outURL.path)")
