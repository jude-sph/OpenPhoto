#!/usr/bin/swift
// Usage: swift scripts/gen-fixtures.swift [count] [outputDir] [seedOffset]
// Generates a nested mock library of small JPEGs with varied EXIF dates/GPS.
// Repo-local only — never touches real photo folders.
import Foundation
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

let count = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 300 : 300
let rootPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fixtures-library"
let seedOffset = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 0 : 0
let root = URL(fileURLWithPath: rootPath)
let folders = ["rome2022", "canada23", "mac-screenshots/2024", "2025/lisbon25", "_inbox"]
let fm = FileManager.default

func writeJPEG(to url: URL, date: String, lat: Double?, lon: Double?, hue: Double) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    ctx.setFillColor(CGColor(red: 1 - hue, green: hue, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 80 + hue * 100, y: 60, width: 120, height: 120))
    var props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "FixtureCam"],
    ]
    if let lat, let lon {
        props[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
        ]
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let places: [(Double, Double)?] = [(41.9, 12.5), (51.18, -115.57), nil, (38.71, -9.14), nil]
for i in 0..<count {
    let seed = i + seedOffset
    let f = seed % folders.count
    let day = 1 + (seed % 27), month = 1 + (seed % 12), year = 2021 + (seed % 5)
    let date = String(format: "%04d:%02d:%02d %02d:00:00", year, month, day, seed % 24)
    writeJPEG(to: root.appendingPathComponent("\(folders[f])/IMG_\(1000 + seed).jpg"),
              date: date, lat: places[f]?.0, lon: places[f]?.1,
              hue: Double(seed % 100) / 100)
}
print("Generated \(count) JPEGs in \(root.path)")
