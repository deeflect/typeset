#!/usr/bin/env swift
// Generates the M6 Phase 0 image-heavy fixture: ~100 local PNGs + a
// Markdown file referencing them, for the many-image scroll gate
// (M6-PLAN.md §6/§7). Run via `swift Scripts/make-image-fixtures.swift`.
import AppKit
import Foundation

let outDir = "Tests/Fixtures/generated/images"
let imagesSubdir = "img"
try? FileManager.default.createDirectory(
    atPath: "\(outDir)/\(imagesSubdir)", withIntermediateDirectories: true)

let count = 100
let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemTeal, .systemPurple]

func writePNG(color: NSColor, index: Int, size: CGSize) {
    let image = NSImage(size: size)
    image.lockFocus()
    color.withAlphaComponent(0.85).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    NSColor.black.withAlphaComponent(0.15).setStroke()
    NSBezierPath(rect: NSRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)).stroke()
    let label = "img \(index)" as NSString
    label.draw(at: NSPoint(x: 12, y: size.height / 2 - 10), withAttributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else { return }
    let path = "\(outDir)/\(imagesSubdir)/photo-\(index).png"
    try? png.write(to: URL(fileURLWithPath: path))
}

// A plausible README-with-screenshots mix: mostly ~800x500 "screenshot"
// sized images, a few larger ones, interspersed with prose.
var markdown = "# Image-heavy fixture\n\nSynthetic fixture for the M6 Phase 0 many-image scroll gate — \(count) local PNGs interspersed with prose, sized like real README screenshots.\n\n"
for i in 1...count {
    let size = (i % 7 == 0) ? CGSize(width: 1200, height: 800) : CGSize(width: 800, height: 500)
    writePNG(color: colors[i % colors.count], index: i, size: size)
    markdown += """
    ## Section \(i)

    Paragraph \(i) with some **bold**, _italic_, and `inline code` — a plausible mix of prose around each screenshot.

    ![Screenshot \(i)](\(imagesSubdir)/photo-\(i).png)

    """
    markdown += "\n"
}

try? markdown.write(toFile: "\(outDir)/image-heavy.md", atomically: true, encoding: .utf8)
print("Wrote \(count) images + \(outDir)/image-heavy.md (\(markdown.utf8.count) bytes)")
