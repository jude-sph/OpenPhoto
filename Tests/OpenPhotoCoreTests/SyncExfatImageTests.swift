import Testing
import Foundation
@testable import OpenPhotoCore

@discardableResult
private func run(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

/// Create + attach a small exFAT image; returns (mountPoint, devNode) or nil if unavailable.
private func attachExfatImage(_ t: TestDirs, sizeMB: Int = 48) throws -> (URL, String)? {
    let dmg = t.root.appendingPathComponent("drive.dmg")
    let create = run(["hdiutil", "create", "-size", "\(sizeMB)m", "-fs", "ExFAT",
                      "-volname", "OPCanon", "-ov", dmg.path])
    guard create.status == 0 else { return nil }
    let attach = run(["hdiutil", "attach", dmg.path, "-nobrowse"])
    guard attach.status == 0 else { return nil }
    for line in attach.out.split(separator: "\n") {
        if line.contains("/Volumes/") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let mount = cols.last, mount.hasPrefix("/Volumes/"),
               let dev = cols.first(where: { $0.hasPrefix("/dev/") }) {
                return (URL(fileURLWithPath: mount), dev)
            }
        }
    }
    return nil
}

@Test func syncToRealExfatImage() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    guard let (mount, dev) = try attachExfatImage(t) else { return } // skip if unavailable
    defer { _ = run(["hdiutil", "detach", dev, "-force"]) }

    let pics = try t.sub("Pictures")
    try makeJPEG(at: pics.appendingPathComponent("rome/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    let lib = try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as"))
    try await lib.scanAll()

    let driveRoot = mount.appendingPathComponent("OpenPhoto")
    try FileManager.default.createDirectory(at: driveRoot, withIntermediateDirectories: true)
    let drive = try Vault.openOrCreate(at: driveRoot, role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: driveRoot)
    let result = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                    destinationVault: drive, volume: vol)
    #expect(result.copied == 1)
    #expect(result.failed.isEmpty)
    let dest = driveRoot.appendingPathComponent("Pictures/rome/IMG_1.jpg")
    #expect(try Data(contentsOf: dest) == (try Data(contentsOf:
        pics.appendingPathComponent("rome/IMG_1.jpg"))))
}
