#!/usr/bin/env swift
//
// Genera l'icona di Game-X: squircle con gradiente + gamepad stilizzato (senza testo).
// Produce un iconset e, se disponibile, AppIcon.icns.
//
// Uso: swift scripts/make-icon.swift [outputDir]
//
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
let logoPath = outDir.appendingPathComponent("Logo.png").path
let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

/// Disegna l'icona in un contesto di lato `s`.
func draw(size s: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    NSColor.clear.set()
    rect.fill()

    // Colore di fondo scuro, vicino a quello del logo neon (che ha lo sfondo del gamepad)
    let bgColor = rgb(38, 43, 51)

    // Squircle con gradiente scuro
    let inset = s * 0.06
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                          xRadius: s * 0.225, yRadius: s * 0.225)
    let gradient = NSGradient(colors: [rgb(20, 24, 30), rgb(46, 52, 61), rgb(16, 20, 26)])!
    gradient.draw(in: bg, angle: -60)

    // Logo (se presente): neon X su sfondo gamepad, con dissolvenza radiale
    // verso il colore di fondo così spariscono bordo/quadrato del crop.
    if let logo = NSImage(contentsOfFile: logoPath) {
        let side = s * 0.64
        let logoRect = NSRect(x: (s - side) / 2, y: (s - side) / 2,
                              width: side, height: side)
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        // Dissolvenza radiale: centro trasparente → bordo colore di fondo (opaca presto,
        // così spariscono i residui del gamepad ai margini del crop).
        let center = NSRect(x: s * 0.5 - s * 0.50, y: s * 0.5 - s * 0.50,
                            width: s * 1.00, height: s * 1.00)
        let fade = NSGradient(colorsAndLocations:
            (bgColor.withAlphaComponent(0.0), 0.0),
            (bgColor.withAlphaComponent(0.0), 0.45),
            (bgColor.withAlphaComponent(0.9), 0.68),
            (bgColor.withAlphaComponent(1.0), 0.80))!
        fade.draw(in: NSBezierPath(ovalIn: center), relativeCenterPosition: .zero)
    } else {
        drawVectorGamepad(size: s, cx: s * 0.5, cy: s * 0.5)
    }

    // Bordo luminoso sopra tutto
    rgb(90, 170, 220, 0.55).setStroke()
    bg.lineWidth = max(1, s * 0.012)
    bg.stroke()
}

/// Fallback: gamepad vettoriale (se Resources/Logo.png non è disponibile).
func drawVectorGamepad(size s: CGFloat, cx: CGFloat, cy: CGFloat) {
    let bodyW = s * 0.60, bodyH = s * 0.30
    let gripR = s * 0.155
    let pad = NSBezierPath()
    pad.appendRoundedRect(NSRect(x: cx - bodyW/2, y: cy - bodyH/2 + s*0.02, width: bodyW, height: bodyH),
                          xRadius: bodyH/2, yRadius: bodyH/2)
    pad.appendOval(in: NSRect(x: cx - bodyW/2 + s*0.05 - gripR, y: cy - gripR - s*0.01, width: gripR*2, height: gripR*2))
    pad.appendOval(in: NSRect(x: cx + bodyW/2 - s*0.05 - gripR, y: cy - gripR - s*0.01, width: gripR*2, height: gripR*2))
    pad.windingRule = .nonZero
    rgb(236, 246, 252).setFill()
    pad.fill()
    rgb(30, 50, 70, 0.85).setFill()
    let d = s * 0.028
    let dpadX = cx - s * 0.155, dpadY = cy + s * 0.005
    NSBezierPath(roundedRect: NSRect(x: dpadX - d/2, y: dpadY - d*1.4, width: d, height: d*2.8), xRadius: d*0.3, yRadius: d*0.3).fill()
    NSBezierPath(roundedRect: NSRect(x: dpadX - d*1.4, y: dpadY - d/2, width: d*2.8, height: d), xRadius: d*0.3, yRadius: d*0.3).fill()
    for (dx, dy) in [(0.145, 0.055), (0.185, -0.005)] {
        let r = s * 0.030
        NSBezierPath(ovalIn: NSRect(x: cx + s*dx - r, y: cy + s*dy - r, width: r*2, height: r*2)).fill()
    }
}

func renderPNG(pixels: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

// Set standard per iconutil
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in variants {
    renderPNG(pixels: px, to: iconsetDir.appendingPathComponent(name))
}
// PNG principale per la GUI SwiftUI / README
renderPNG(pixels: 512, to: outDir.appendingPathComponent("AppIcon-512.png"))

// .icns
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try? proc.run()
proc.waitUntilExit()

print("Icona generata in \(outDir.path) (iconset + AppIcon.icns)")
