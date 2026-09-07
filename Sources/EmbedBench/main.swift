import Foundation
import CoreML
import CoreImage
import ImageIO
import OpenPhotoCore

// Benchmarks candidate CLIP-family image encoders against a real library: how fast each embeds a
// photo on this Mac, and how good its top hits look for a fixed set of text queries.
//
// Only the IMAGE half runs here. Text embeddings are precomputed per candidate by
// tools/embed-bench/convert.py, because the three families tokenise differently and reimplementing
// three tokenisers to benchmark them would be work thrown away. The image half is the one that
// matters for speed anyway — it runs once per photo across the whole library.
//
// Output is a local HTML file. Photos stay on this machine; nothing is uploaded.

// MARK: - Inputs

struct Candidate {
    let key: String
    let modelURL: URL
    let side: Int
    let dim: Int
    let licence: String
    let imageInput: String
    let output: String
}

struct Args {
    var benchDir = "tools/embed-bench"
    var libraryRoot: URL?
    var sampleSize = 400
    var topK = 8
    var out = "/tmp/embed-bench.html"
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let f = it.next() {
        switch f {
        case "--bench-dir":  a.benchDir = it.next() ?? a.benchDir
        case "--library":    a.libraryRoot = it.next().map { URL(fileURLWithPath: $0) }
        case "--sample":     a.sampleSize = it.next().flatMap { Int($0) } ?? a.sampleSize
        case "--top":        a.topK = it.next().flatMap { Int($0) } ?? a.topK
        case "--out":        a.out = it.next() ?? a.out
        default:
            FileHandle.standardError.write(Data("unknown flag: \(f)\n".utf8))
            exit(2)
        }
    }
    return a
}

let args = parseArgs()
let benchDir = URL(fileURLWithPath: args.benchDir)
let modelsDir = benchDir.appendingPathComponent("models")

guard let libraryRoot = args.libraryRoot else {
    print("""
    usage: EmbedBench --library <photo-dir> [--bench-dir tools/embed-bench]
                      [--sample 400] [--top 8] [--out /tmp/embed-bench.html]
    """)
    exit(2)
}

// MARK: - Manifest

struct ManifestEntry: Decodable {
    let dim: Int
    let side: Int
    let licence: String
    let prebuilt: Bool
    let image_input: String
    let output: String
}

let manifestURL = modelsDir.appendingPathComponent("manifest.json")
guard let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode([String: ManifestEntry].self, from: manifestData) else {
    FileHandle.standardError.write(Data("missing or unreadable \(manifestURL.path) — run convert.py first\n".utf8))
    exit(1)
}

// Query text -> candidate key -> unit-normalised text embedding.
let queriesURL = modelsDir.appendingPathComponent("queries.json")
guard let qData = try? Data(contentsOf: queriesURL),
      var queryVectors = try? JSONDecoder().decode([String: [String: [Float]]].self, from: qData) else {
    FileHandle.standardError.write(Data("missing or unreadable \(queriesURL.path)\n".utf8))
    exit(1)
}

// convert.py can only produce text vectors for candidates it loads through transformers, so the
// prebuilt MobileCLIP baseline arrives with none — leaving the one comparison that matters most
// ("what would switching cost me?") blank. It ships its own Core ML text encoder and BPE vocab, so
// fill them in here instead, reusing the app's own tokenizer so the tokenisation is identical to
// what the shipping search path does.
@MainActor
func fillMobileCLIPTextVectors(into vectors: inout [String: [String: [Float]]], modelsRoot: URL) {
    let key = "mobileclip_s2"
    guard vectors.values.contains(where: { $0[key] == nil }) else { return }
    let textPackage = modelsRoot.appendingPathComponent("mobileclip_s2_text.mlpackage")
    guard FileManager.default.fileExists(atPath: textPackage.path),
          let tok = CLIPTokenizer(vocabDirectory: modelsRoot),
          let compiled = try? MLModel.compileModel(at: textPackage),
          let model = try? MLModel(contentsOf: compiled, configuration: config) else {
        print("note: \(key) text encoder unavailable — it will be timed but not ranked")
        return
    }
    var filled = 0
    for query in vectors.keys {
        let ids = tok.encode(query)
        guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)],
                                          dataType: .int32) else { continue }
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        for (i, id) in ids.enumerated() { ptr[i] = id }
        guard let input = try? MLDictionaryFeatureProvider(
                dictionary: ["text": MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: input),
              let v = vector(from: out, name: "final_emb_1", dim: 512) else { continue }
        vectors[query]?[key] = v
        filled += 1
    }
    print("filled \(filled) \(key) text vectors natively")
}

// A prebuilt candidate lives in the app's own model dir rather than models/.
func modelPath(for key: String, entry: ManifestEntry) -> URL? {
    let local = modelsDir.appendingPathComponent("\(key)_image.mlpackage")
    if FileManager.default.fileExists(atPath: local.path) { return local }
    if entry.prebuilt {
        let shipped = URL(fileURLWithPath: ".models/Resources/\(key)_image.mlpackage")
        if FileManager.default.fileExists(atPath: shipped.path) { return shipped }
    }
    return nil
}

var candidates: [Candidate] = []
for (key, e) in manifest.sorted(by: { $0.key < $1.key }) {
    guard let url = modelPath(for: key, entry: e) else {
        print("skip \(key): no .mlpackage found")
        continue
    }
    candidates.append(Candidate(key: key, modelURL: url, side: e.side, dim: e.dim,
                                licence: e.licence, imageInput: e.image_input, output: e.output))
}
guard !candidates.isEmpty else {
    FileHandle.standardError.write(Data("no candidate models found\n".utf8))
    exit(1)
}

// MARK: - Sample the library

let photoExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]
var allPhotos: [URL] = []
if let en = FileManager.default.enumerator(at: libraryRoot,
                                           includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles]) {
    for case let u as URL in en where photoExts.contains(u.pathExtension.lowercased()) {
        allPhotos.append(u)
    }
}
guard !allPhotos.isEmpty else {
    FileHandle.standardError.write(Data("no photos under \(libraryRoot.path)\n".utf8))
    exit(1)
}
// Deterministic even spread across the library, so reruns are comparable and the sample isn't all
// from one folder (which would be one trip, one subject, one camera).
let stride = max(1, allPhotos.count / args.sampleSize)
let sample = Swift.stride(from: 0, to: allPhotos.count, by: stride).prefix(args.sampleSize).map { allPhotos[$0] }
print("library: \(allPhotos.count) photos, sampling \(sample.count)")

// MARK: - Core ML

/// Full compute-unit access so the ANE is used where the model supports it — this is the number
/// that matters, since it is what a real index run would see.
let config: MLModelConfiguration = {
    let c = MLModelConfiguration()
    c.computeUnits = .all
    return c
}()

func makePixelBuffer(from url: URL, side: Int) -> CVPixelBuffer? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                              kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let ctx = CGContext(data: base, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    // Aspect-fill into the square the encoder expects, matching how the app crops for embedding.
    let s = max(CGFloat(side) / CGFloat(cg.width), CGFloat(side) / CGFloat(cg.height))
    let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
    ctx.draw(cg, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
    return buffer
}

func vector(from provider: MLFeatureProvider, name: String, dim: Int) -> [Float]? {
    guard let v = provider.featureValue(for: name)?.multiArrayValue else { return nil }
    var out = [Float](repeating: 0, count: dim)
    let n = min(dim, v.count)
    for i in 0..<n { out[i] = v[i].floatValue }
    // The graphs L2-normalise already; renormalise defensively so cosine is a plain dot product.
    let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
    if norm > 0 { for i in 0..<out.count { out[i] /= norm } }
    return out
}

// Safe here and not earlier: this is main.swift, so `config` and `vector(from:…)` above must already
// have been initialised before anything calls into them.
fillMobileCLIPTextVectors(into: &queryVectors,
                          modelsRoot: URL(fileURLWithPath: ".models/Resources"))

struct Result {
    let key: String
    var perImageMs: Double = 0
    var loadMs: Double = 0
    var sizeMB: Double = 0
    var embeddings: [(url: URL, vec: [Float])] = []
}

var results: [Result] = []

for c in candidates {
    print("\n[\(c.key)] loading …")
    var r = Result(key: c.key)
    r.sizeMB = Double((try? FileManager.default.allocatedSizeOfDirectory(at: c.modelURL)) ?? 0) / 1_048_576

    let t0 = Date()
    // Compiling is a one-off cost the app pays once, so it's reported separately from per-image time.
    guard let compiled = try? MLModel.compileModel(at: c.modelURL),
          let model = try? MLModel(contentsOf: compiled, configuration: config) else {
        print("[\(c.key)] FAILED to load — skipping")
        continue
    }
    r.loadMs = Date().timeIntervalSince(t0) * 1000

    // Warm up before timing: the first inference pays ANE weight-load and graph setup, which would
    // otherwise be charged to whichever photo happened to go first.
    if let warm = makePixelBuffer(from: sample[0], side: c.side),
       let input = try? MLDictionaryFeatureProvider(
            dictionary: [c.imageInput: MLFeatureValue(pixelBuffer: warm)]) {
        _ = try? model.prediction(from: input)
    }

    var totalInference: Double = 0
    var counted = 0
    for url in sample {
        autoreleasepool {
            guard let pb = makePixelBuffer(from: url, side: c.side),
                  let input = try? MLDictionaryFeatureProvider(
                    dictionary: [c.imageInput: MLFeatureValue(pixelBuffer: pb)]) else { return }
            let t = Date()
            guard let out = try? model.prediction(from: input) else { return }
            totalInference += Date().timeIntervalSince(t) * 1000
            counted += 1
            if let v = vector(from: out, name: c.output, dim: c.dim) {
                r.embeddings.append((url, v))
            }
        }
    }
    r.perImageMs = counted > 0 ? totalInference / Double(counted) : 0
    print(String(format: "[%@] %.2f ms/image over %d images · load %.0f ms · %.0f MB",
                 c.key, r.perImageMs, counted, r.loadMs, r.sizeMB))
    results.append(r)
}

guard !results.isEmpty else {
    FileHandle.standardError.write(Data("no candidate produced results\n".utf8))
    exit(1)
}

// MARK: - Rank and report

func topMatches(_ r: Result, query: String, k: Int) -> [(URL, Float)] {
    guard let tvec = queryVectors[query]?[r.key], !tvec.isEmpty else { return [] }
    var scored: [(URL, Float)] = []
    scored.reserveCapacity(r.embeddings.count)
    for (url, v) in r.embeddings where v.count == tvec.count {
        var dot: Float = 0
        for i in 0..<v.count { dot += v[i] * tvec[i] }
        scored.append((url, dot))
    }
    return Array(scored.sorted { $0.1 > $1.1 }.prefix(k))
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

var html = """
<!doctype html><html><head><meta charset="utf-8"><title>Embedding model comparison</title>
<style>
:root{color-scheme:dark}
body{background:#141414;color:#e8e8e8;font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:0 24px 60px}
header{position:sticky;top:0;background:#141414ee;backdrop-filter:blur(8px);padding:18px 0 12px;border-bottom:1px solid #2c2c2c;margin-bottom:18px}
h1{font-size:19px;margin:0 0 10px}
table.sum{border-collapse:collapse;font-size:12.5px}
table.sum th,table.sum td{text-align:left;padding:5px 14px 5px 0}
table.sum th{color:#8a8a8a;font-weight:500}
.lic-ok{color:#6fc78f}.lic-bad{color:#c96a6a}
h2{font-size:15px;margin:30px 0 8px;color:#ddd}
.row{display:grid;grid-template-columns:130px 1fr;gap:12px;align-items:start;margin-bottom:10px}
.mk{font:12px ui-monospace,Menlo,monospace;color:#9a9a9a;padding-top:28px}
.strip{display:flex;gap:6px;overflow-x:auto;padding-bottom:6px}
.hit{flex:0 0 auto;width:104px}
.hit img{width:104px;height:104px;object-fit:cover;border-radius:6px;display:block;background:#000;border:1px solid #2a2a2a}
.sc{font:10px ui-monospace,Menlo,monospace;color:#777;text-align:center;margin-top:3px}
</style></head><body>
<header><h1>Embedding model comparison</h1>
<table class="sum"><tr><th>model</th><th>licence</th><th>ms / image</th><th>size</th><th>dim</th><th>load</th></tr>
"""
for r in results {
    let c = candidates.first { $0.key == r.key }!
    let permissive = !c.licence.lowercased().contains("research")
    html += String(format: """
    <tr><td><b>%@</b></td><td class="%@">%@</td><td>%.2f</td><td>%.0f MB</td><td>%d</td><td>%.0f ms</td></tr>
    """, esc(r.key), permissive ? "lic-ok" : "lic-bad", esc(c.licence),
         r.perImageMs, r.sizeMB, c.dim, r.loadMs)
}
let est = results.map { ($0.key, $0.perImageMs * Double(allPhotos.count) / 1000 / 60) }
html += "</table><p style=\"color:#8a8a8a;font-size:12px;margin:8px 0 0\">"
html += "Estimated full-library pass over \(allPhotos.count) photos: "
html += est.map { String(format: "%@ %.1f min", $0.0, $0.1) }.joined(separator: " · ")
html += "</p></header>"

for query in queryVectors.keys.sorted() {
    html += "<h2>\(esc(query))</h2>"
    for r in results {
        let hits = topMatches(r, query: query, k: args.topK)
        if hits.isEmpty { continue }
        html += "<div class=\"row\"><div class=\"mk\">\(esc(r.key))</div><div class=\"strip\">"
        for (url, score) in hits {
            let enc = url.absoluteString
            html += "<div class=\"hit\"><img loading=\"lazy\" src=\"\(esc(enc))\">"
            html += String(format: "<div class=\"sc\">%.3f</div></div>", score)
        }
        html += "</div></div>"
    }
}
html += "</body></html>"

try? html.write(toFile: args.out, atomically: true, encoding: .utf8)
print("\nwrote \(args.out)")

// MARK: - Helpers

extension FileManager {
    /// .mlpackage is a directory; report what it actually occupies.
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let en = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
