#!/usr/bin/env swift
//
// Generates the app icon master PNG (1024×1024) for Slip.
//
// Design: a small stack of paper slips on an indigo→deep-purple
// squircle background, evoking the Zettelkasten "slip-box" the app
// is named after. Three off-set sheets imply the second-brain idea
// of many small, connected notes; the topmost sheet carries three
// short text-line strokes so the silhouette still reads as "a note"
// at small sizes.
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

// MARK: - Paper slips

let center = CGPoint(x: masterSize / 2, y: masterSize / 2)
let paperWidth: CGFloat = masterSize * 0.50
let paperHeight: CGFloat = masterSize * 0.66

func drawPaper(offsetX: CGFloat, offsetY: CGFloat, rotationDeg: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x + offsetX, y: center.y + offsetY)
    ctx.rotate(by: rotationDeg * .pi / 180)

    let r = NSRect(
        x: -paperWidth / 2,
        y: -paperHeight / 2,
        width: paperWidth,
        height: paperHeight
    )
    let path = NSBezierPath(roundedRect: r, xRadius: 38, yRadius: 38)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 28
    shadow.set()

    NSColor(srgbRed: 0.992, green: 0.984, blue: 0.965, alpha: alpha).setFill()
    path.fill()

    // Reset shadow so following strokes don't inherit it.
    NSShadow().set()
    ctx.restoreGState()
}

// Back-most slip (most rotated, dimmer)
drawPaper(offsetX: -110, offsetY: -50, rotationDeg: -10, alpha: 0.86)
// Middle slip
drawPaper(offsetX:   60, offsetY:  10, rotationDeg:   5, alpha: 0.93)
// Front slip — gets the text strokes
drawPaper(offsetX:  -20, offsetY:  60, rotationDeg:  -3, alpha: 1.00)

// MARK: - Text strokes on the front slip

ctx.saveGState()
ctx.translateBy(x: center.x - 20, y: center.y + 60)
ctx.rotate(by: -3 * .pi / 180)

let strokeColor = NSColor(srgbRed: 0.43, green: 0.32, blue: 0.85, alpha: 0.55)
strokeColor.setFill()

let strokeHeight: CGFloat = 30
let strokeGap: CGFloat = 86
let strokeStartX = -paperWidth / 2 + 78

let lineLengths: [CGFloat] = [0.74, 0.66, 0.46]
for (i, frac) in lineLengths.enumerated() {
    let y: CGFloat = 100 - CGFloat(i) * strokeGap
    let w = (paperWidth - 156) * frac
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
