#!/usr/bin/env swift
// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

// Renders the DMG window background next to this file at 1x and 2x.
// Geometry matches settings.py: a 640x400 window with the app icon centred
// at (170, 190) and the Applications link at (470, 190); the arrow runs
// between them and the caption sits below the icon labels.
//
//   swift Scripts/dmg/render-background.swift

import AppKit

let size = NSSize(width: 640, height: 400)
let indigo = NSColor(srgbRed: 0.1098, green: 0.1216, blue: 0.3608, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context

    // Flip so the coordinates below read top-down like the Finder layout.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)

    NSGradient(
        starting: NSColor(srgbRed: 0.980, green: 0.980, blue: 0.988, alpha: 1),
        ending: NSColor(srgbRed: 0.925, green: 0.925, blue: 0.953, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: 90)

    // Arrow from the app icon towards Applications.
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 268, y: 190))
    arrow.line(to: NSPoint(x: 372, y: 190))
    arrow.move(to: NSPoint(x: 352, y: 172))
    arrow.line(to: NSPoint(x: 372, y: 190))
    arrow.line(to: NSPoint(x: 352, y: 208))
    indigo.withAlphaComponent(0.55).setStroke()
    arrow.stroke()

    let caption = "Drag Constellation to Applications to install"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.50, alpha: 1),
    ]
    let text = NSAttributedString(string: caption, attributes: attributes)
    let textSize = text.size()
    // Text draws upright in a flipped context only when the context says so.
    context.cgContext.saveGState()
    context.cgContext.translateBy(x: (size.width - textSize.width) / 2, y: 340)
    context.cgContext.scaleBy(x: 1, y: -1)
    text.draw(at: NSPoint(x: 0, y: -textSize.height))
    context.cgContext.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    let url = directory.appendingPathComponent(name)
    try render(scale: scale).write(to: url)
    print("wrote \(url.path)")
}
