#!/usr/bin/env swift
//
// Estrae il logo neon usando saturazione E luminosità come chiave.
// Crea un bitmap RGBA esplicito (i JPEG non hanno alpha) e rende trasparenti
// i pixel scuri/desaturati (gamepad, sfondo), tenendo le linee neon.
//
// Uso: swift scripts/key-logo.swift <input> <output.png> [satMin] [valMin]
//
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]) else {
    FileHandle.standardError.write(Data("uso: key-logo.swift <input> <out.png> [satMin] [valMin]\n".utf8))
    exit(1)
}
let satMin = a.count > 3 ? Double(a[3])! : 0.15
let valMin = a.count > 4 ? Double(a[4])! : 0.40
let satSoft = 0.25, valSoft = 0.25

let w = Int(img.size.width), h = Int(img.size.height)
guard let out = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

guard let data = out.bitmapData else { exit(1) }
let spp = out.samplesPerPixel, rowBytes = out.bytesPerRow
func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

for y in 0..<h {
    let row = data + y * rowBytes
    for x in 0..<w {
        let p = row + x * spp
        let r = Double(p[0]) / 255, g = Double(p[1]) / 255, b = Double(p[2]) / 255
        let maxc = max(r, g, b), minc = min(r, g, b)
        let sat = maxc > 0 ? (maxc - minc) / maxc : 0
        let alpha = clamp01((sat - satMin) / satSoft) * clamp01((maxc - valMin) / valSoft)
        p[3] = UInt8(alpha * 255)
    }
}

guard let png = out.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: a[2]))
print("scritto \(a[2]) (\(w)x\(h)) spp=\(spp) satMin=\(satMin) valMin=\(valMin)")
