#!/usr/bin/env swift
//
// Ritaglia un rettangolo da un'immagine.
// Uso: swift scripts/crop-image.swift <input> <x> <y> <w> <h> <output.png>
//
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 7,
      let x = Int(a[2]), let y = Int(a[3]), let w = Int(a[4]), let h = Int(a[5]),
      let img = NSImage(contentsOfFile: a[1]),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("uso: crop-image.swift <input> <x> <y> <w> <h> <out.png>\n".utf8))
    exit(1)
}
guard let cg = rep.cgImage?.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
    FileHandle.standardError.write(Data("crop fallito\n".utf8)); exit(1)
}
let out = NSBitmapImageRep(cgImage: cg)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[6]))
print("scritto \(a[6]) (\(cg.width)x\(cg.height))")
