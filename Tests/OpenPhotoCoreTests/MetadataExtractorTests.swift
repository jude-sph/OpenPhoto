import Testing
import Foundation
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers
@testable import OpenPhotoCore

/// Write a 4×4 JPEG with EXIF date, GPS, and camera model.
func makeJPEG(at url: URL, dateTimeOriginal: String?, lat: Double?, lon: Double?) throws {
    let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let image = ctx.makeImage()!
    var props: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam X1"],
    ]
    if let d = dateTimeOriginal {
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: d]
    }
    if let lat, let lon {
        props[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(lat),
            kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(lon),
            kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
        ]
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

/// Write a ~1-second 64×64 H.264 .mov.
func makeMOV(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    for i in 0..<2 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i * 30), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Test func extractsImageMetadata() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("test.jpg")
    try makeJPEG(at: url, dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.90, lon: 12.50)
    let m = MetadataExtractor.extract(from: url, kind: .photo)
    #expect(m.pixelWidth == 4 && m.pixelHeight == 4)
    #expect(m.cameraModel == "TestCam X1")
    #expect(m.latitude != nil && abs(m.latitude! - 41.90) < 0.01)
    #expect(m.longitude != nil && abs(m.longitude! - 12.50) < 0.01)
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month, .day], from: m.takenAt)
    #expect(comps.year == 2022 && comps.month == 10 && comps.day == 7)
}

@Test func fallsBackToFileMtimeWhenNoExif() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("noexif.jpg")
    try makeJPEG(at: url, dateTimeOriginal: nil, lat: nil, lon: nil)
    let m = MetadataExtractor.extract(from: url, kind: .photo)
    let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    #expect(abs(m.takenAt.timeIntervalSince(mtime)) < 2)
    #expect(m.latitude == nil)
}

@Test func extractsVideoMetadata() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let url = t.root.appendingPathComponent("clip.mov")
    try await makeMOV(at: url)
    let m = MetadataExtractor.extract(from: url, kind: .video)
    #expect(m.pixelWidth == 64 && m.pixelHeight == 64)
    #expect(m.durationSeconds != nil && m.durationSeconds! > 0)
}
