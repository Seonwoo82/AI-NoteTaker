#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

struct IconImage {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String { "app-icon-\(points)x\(points)@\(scale)x.png" }
    var contentsJSONEntry: String {
        """
            {
              "filename" : "\(filename)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(points)x\(points)"
            }
        """
    }
}

let images = [
    IconImage(points: 16, scale: 1),
    IconImage(points: 16, scale: 2),
    IconImage(points: 32, scale: 1),
    IconImage(points: 32, scale: 2),
    IconImage(points: 128, scale: 1),
    IconImage(points: 128, scale: 2),
    IconImage(points: 256, scale: 1),
    IconImage(points: 256, scale: 2),
    IconImage(points: 512, scale: 1),
    IconImage(points: 512, scale: 2)
]

let fileManager = FileManager.default
let repositoryRoot = URL(filePath: fileManager.currentDirectoryPath)
let iconSetURL = repositoryRoot
    .appending(path: "NoteTaker/Resources/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
    .standardizedFileURL
let allowedRoot = repositoryRoot
    .appending(path: "NoteTaker/Resources/Assets.xcassets", directoryHint: .isDirectory)
    .standardizedFileURL

guard iconSetURL.path.hasPrefix(allowedRoot.path + "/") else {
    fatalError("Refusing to write outside Assets.xcassets")
}

try fileManager.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

func drawIcon(size: Int) -> NSImage {
    let canvas = CGSize(width: size, height: size)
    let image = NSImage(size: canvas)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Could not create graphics context")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let rect = CGRect(origin: .zero, size: canvas)
    let radius = CGFloat(size) * 0.215
    let background = CGPath(roundedRect: rect.insetBy(dx: CGFloat(size) * 0.035, dy: CGFloat(size) * 0.035), cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(background)
    context.setFillColor(NSColor(calibratedRed: 0.16, green: 0.165, blue: 0.175, alpha: 1).cgColor)
    context.fillPath()

    let inset = CGFloat(size) * 0.09
    let inner = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: radius * 0.72, cornerHeight: radius * 0.72, transform: nil)
    context.addPath(inner)
    context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.13).cgColor)
    context.setLineWidth(max(1, CGFloat(size) * 0.018))
    context.strokePath()

    let diskDiameter = CGFloat(size) * 0.54
    let diskRect = CGRect(
        x: (CGFloat(size) - diskDiameter) / 2,
        y: CGFloat(size) * 0.235,
        width: diskDiameter,
        height: diskDiameter
    )
    context.setFillColor(NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.095, alpha: 1).cgColor)
    context.fillEllipse(in: diskRect)

    let highlightRect = diskRect.insetBy(dx: diskDiameter * 0.18, dy: diskDiameter * 0.18)
    context.setFillColor(NSColor(calibratedRed: 1, green: 0.32, blue: 0.25, alpha: 0.16).cgColor)
    context.fillEllipse(in: highlightRect)

    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(max(1.25, CGFloat(size) * 0.038))

    context.setFillColor(NSColor.white.cgColor)
    let barWidth = CGFloat(size) * 0.045
    let barSpacing = CGFloat(size) * 0.04
    let heights = [0.15, 0.27, 0.39, 0.25, 0.17].map { CGFloat(size) * $0 }
    let totalWidth = barWidth * CGFloat(heights.count) + barSpacing * CGFloat(heights.count - 1)
    let startX = (CGFloat(size) - totalWidth) / 2
    let centerY = CGFloat(size) * 0.66

    for (index, height) in heights.enumerated() {
        let x = startX + CGFloat(index) * (barWidth + barSpacing)
        let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        context.fillPath()
    }

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let png = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(url.lastPathComponent)")
    }
    try png.write(to: url, options: .atomic)
}

for image in images {
    try writePNG(drawIcon(size: image.pixels), to: iconSetURL.appending(path: image.filename))
}

let contents = """
{
  "images" : [
\(images.map(\.contentsJSONEntry).joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

try contents.write(to: iconSetURL.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
