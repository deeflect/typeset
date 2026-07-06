#!/usr/bin/env swift
// Generates a placeholder AppIcon programmatically: a rounded document
// "page" with a folded corner and a stack of heading/text glyph bars
// (echoing the reading view's own typographic ramp), in light, dark, and
// tinted variants. This is a stand-in for a real Tahoe layered Icon
// Composer icon (see PLAN.md M5 notes) — headless authoring of the actual
// `.icon` bundle format isn't supported by any documented CLI as of
// Xcode 26.3 (Icon Composer is GUI-only), so this script instead produces
// a traditional 1024px asset-catalog icon that still looks intentional in
// the Dock/Finder rather than the generic default.
//
// Usage: swift Scripts/generate-icon.swift
// Writes App/Sources/Marco/Resources/Assets.xcassets/AppIcon.appiconset/*.png
// plus its Contents.json.

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let appIconSet = root
    .appendingPathComponent("App/Sources/Marco/Resources/Assets.xcassets/AppIcon.appiconset")

try? FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)

enum Variant: String, CaseIterable {
    case light, dark, tinted
}

func drawIcon(size: CGFloat, variant: Variant) -> NSBitmapImageRep {
    let pixels = Int(size.rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("could not allocate bitmap for size \(size)")
    }
    // Draw at exact device pixels — no point-space/backing-scale doubling —
    // so every requested size (16pt@1x through 512pt@2x) comes out at the
    // exact pixel dimensions Xcode's asset catalog compiler expects.
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        fatalError("could not create graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    let inset = size * 0.08
    let pageRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = size * 0.22

    // Background: full-bleed rounded square, per Tahoe App Icon convention
    // (the system applies its own mask/shine — we just fill edge to edge).
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                         cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
    ctx.addPath(bgPath)
    switch variant {
    case .light:
        ctx.setFillColor(CGColor(red: 0.965, green: 0.960, blue: 0.945, alpha: 1))
    case .dark:
        ctx.setFillColor(CGColor(red: 0.145, green: 0.145, blue: 0.160, alpha: 1))
    case .tinted:
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    }
    ctx.fillPath()

    // The "page": a slightly inset rounded rect with a folded top-right
    // corner, echoing a document/markdown file.
    let pageColor: CGColor
    let foldColor: CGColor
    let accent: CGColor
    switch variant {
    case .light:
        pageColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        foldColor = CGColor(red: 0.88, green: 0.87, blue: 0.85, alpha: 1)
        accent = CGColor(red: 0.20, green: 0.47, blue: 0.98, alpha: 1)
    case .dark:
        pageColor = CGColor(red: 0.24, green: 0.24, blue: 0.27, alpha: 1)
        foldColor = CGColor(red: 0.34, green: 0.34, blue: 0.38, alpha: 1)
        accent = CGColor(red: 0.38, green: 0.62, blue: 1.0, alpha: 1)
    case .tinted:
        pageColor = CGColor(gray: 0.92, alpha: 1)
        foldColor = CGColor(gray: 0.8, alpha: 1)
        accent = CGColor(gray: 0.3, alpha: 1)
    }

    let fold = pageRect.width * 0.26
    let page = CGMutablePath()
    page.move(to: CGPoint(x: pageRect.minX, y: pageRect.minY + corner))
    page.addArc(tangent1End: CGPoint(x: pageRect.minX, y: pageRect.minY),
                tangent2End: CGPoint(x: pageRect.minX + corner, y: pageRect.minY), radius: corner)
    page.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.minY))
    page.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.maxY - fold))
    page.addLine(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.maxY))
    page.addLine(to: CGPoint(x: pageRect.minX + corner, y: pageRect.maxY))
    page.addArc(tangent1End: CGPoint(x: pageRect.minX, y: pageRect.maxY),
                tangent2End: CGPoint(x: pageRect.minX, y: pageRect.maxY - corner), radius: corner)
    page.closeSubpath()

    ctx.addPath(page)
    ctx.setFillColor(pageColor)
    ctx.fillPath()

    // Folded corner triangle.
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.maxY))
    triangle.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.maxY - fold))
    triangle.addLine(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.maxY - fold))
    triangle.closeSubpath()
    ctx.addPath(triangle)
    ctx.setFillColor(foldColor)
    ctx.fillPath()

    // Heading + text bars: a stand-in for rendered Markdown, matching the
    // reading view's own ramp (bold heading bar, then body-line bars).
    let barX = pageRect.minX + pageRect.width * 0.20
    let barWidth = pageRect.width * 0.44
    let barHeight = pageRect.height * 0.052
    var y = pageRect.maxY - pageRect.height * 0.30

    let headingRect = CGRect(x: barX, y: y, width: barWidth, height: barHeight * 1.6)
    ctx.addPath(CGPath(roundedRect: headingRect, cornerWidth: barHeight * 0.5, cornerHeight: barHeight * 0.5, transform: nil))
    ctx.setFillColor(accent)
    ctx.fillPath()

    y -= barHeight * 2.3
    let widths: [CGFloat] = [0.60, 0.46]
    for w in widths {
        let rect = CGRect(x: barX, y: y, width: pageRect.width * w, height: barHeight)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barHeight * 0.5, cornerHeight: barHeight * 0.5, transform: nil))
        ctx.setFillColor(foldColor)
        ctx.fillPath()
        y -= barHeight * 1.8
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(url.lastPathComponent)\n".utf8))
        return
    }
    try? png.write(to: url)
}

// macOS AppIcon.appiconset needs 16/32/128/256/512 at 1x and 2x (2x shares
// the next size up's pixel dimensions). Render each at full pixel size
// directly rather than downsampling a single 1024 bitmap, so small sizes
// stay crisp.
struct IconSize {
    let point: Int
    let scale: Int
    var pixels: Int { point * scale }
    var filename: String { "icon_\(point)x\(point)@\(scale)x.png" }
}

let sizes = [16, 32, 128, 256, 512].flatMap { point in
    [IconSize(point: point, scale: 1), IconSize(point: point, scale: 2)]
}

var images: [[String: Any]] = []
for size in sizes {
    let img = drawIcon(size: CGFloat(size.pixels), variant: .light)
    writePNG(img, to: appIconSet.appendingPathComponent(size.filename))
    images.append([
        "filename": size.filename,
        "idiom": "mac",
        "scale": "\(size.scale)x",
        "size": "\(size.point)x\(size.point)"
    ])
}

// Also render dark/tinted 1024 previews for reference — *not* into the
// compiled appiconset (an unreferenced file there just risks an asset
// catalog warning); these live next to the script so the eventual real
// Icon Composer pass has a rough visual target for the other appearances.
let previewDir = root.appendingPathComponent("Scripts/icon-preview")
try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
for variant in Variant.allCases where variant != .light {
    let name = "icon_1024_\(variant.rawValue).png"
    let img = drawIcon(size: 1024, variant: variant)
    writePNG(img, to: previewDir.appendingPathComponent(name))
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1]
]

let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: appIconSet.appendingPathComponent("Contents.json"))

print("Wrote \(sizes.count) icon PNGs + Contents.json to \(appIconSet.path)")
print("Note: icon_1024_dark.png / icon_1024_tinted.png are rendered for reference")
print("but not wired into Contents.json — Xcode 26's single-size App Icon with")
print("appearance variants needs authoring via Icon Composer's GUI; this script")
print("only ships the always-correct classic multi-size light icon (PLAN M5 note).")
