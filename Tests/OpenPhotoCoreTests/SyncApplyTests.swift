import Testing
import Foundation
@testable import OpenPhotoCore

private func scannedLibrary(_ t: TestDirs, _ name: String = "Pictures") throws -> LibraryService {
    let pics = try t.sub(name)
    try makeJPEG(at: pics.appendingPathComponent("rome2022/IMG_1.jpg").creatingParent(),
                 dateTimeOriginal: "2022:10:07 14:23:01", lat: 41.9, lon: 12.5)
    try makeJPEG(at: pics.appendingPathComponent("lisbon25/IMG_2.jpg").creatingParent(),
                 dateTimeOriginal: "2025:06:06 09:00:00", lat: nil, lon: nil)
    return try LibraryService(vaultRoots: [pics], appSupportDir: try t.sub("as-" + name))
}

@Test func applyCopiesVerifiesAndUpdatesManifest() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let result = await engine.apply(plan, destinationVault: drive, volume: vol)

    #expect(result.copied == 2)
    #expect(result.failed.isEmpty)
    let a = drive.rootURL.appendingPathComponent("Pictures/rome2022/IMG_1.jpg")
    let src = lib.vaults[0].rootURL.appendingPathComponent("rome2022/IMG_1.jpg")
    #expect(try Data(contentsOf: a) == (try Data(contentsOf: src)))
    let entries = try Manifest.read(from: drive.manifestURL)
    #expect(Set(entries.map(\.path)) == ["Pictures/rome2022/IMG_1.jpg", "Pictures/lisbon25/IMG_2.jpg"])
    #expect(FileManager.default.fileExists(atPath: drive.syncLogURL.path))
    #expect(FileManager.default.fileExists(atPath: lib.vaults[0].syncLogURL.path))
}

@Test func applyWritesSidecar() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    try SidecarStore(vault: lib.vaults[0]).write(
        SidecarData(rating: 4, favorite: false, caption: nil, tags: []),
        forMediaRelPath: "rome2022/IMG_1.jpg")
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let result = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                    destinationVault: drive, volume: vol)
    #expect(result.sidecarsWritten == 1)
    let destSidecar = drive.rootURL.appendingPathComponent("Pictures/rome2022/.openphoto/IMG_1.jpg.xmp")
    #expect(FileManager.default.fileExists(atPath: destSidecar.path))
}

struct FakeVolume: DriveVolume {
    let rootURL: URL
    let free: Int64
    var isMounted: Bool { true }
    func freeSpaceBytes() throws -> Int64 { free }
}

@Test func applyVerifyMismatchIsCleanedAndFailed() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    var plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let bad = plan.copies[0]
    plan.copies[0] = PlanItem(hash: "sha256:" + String(repeating: "f", count: 64),
                              sourceURL: bad.sourceURL, destRelPath: bad.destRelPath, size: bad.size)
    let result = await engine.apply(plan, destinationVault: drive, volume: vol)
    #expect(result.failed.contains { $0.item == plan.copies[0] })
    #expect(!FileManager.default.fileExists(
        atPath: drive.rootURL.appendingPathComponent(bad.destRelPath).path))
}

@Test func applyIsIdempotent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    _ = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                           destinationVault: drive, volume: vol)
    let again = await engine.apply(try engine.plan(sources: lib.vaults, destinationVault: drive),
                                   destinationVault: drive, volume: vol)
    #expect(again.copied == 0)
    #expect(again.failed.isEmpty)
}

@Test func applyResumesWithMatchingPartialAndNeverOverwritesDifferent() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let good = plan.copies[0]
    let goodDest = drive.rootURL.appendingPathComponent(good.destRelPath)
    try FileManager.default.createDirectory(at: goodDest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: good.sourceURL, to: goodDest)
    let other = plan.copies[1]
    let otherDest = drive.rootURL.appendingPathComponent(other.destRelPath)
    try FileManager.default.createDirectory(at: otherDest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("different".utf8).write(to: otherDest)

    let result = await engine.apply(plan, destinationVault: drive, volume: vol)
    #expect(result.skipped == 1)
    #expect(result.failed.contains { $0.item == other })
    #expect(result.conflicts == 1)
    #expect(try Data(contentsOf: otherDest) == Data("different".utf8))
}

/// Mutable box usable from `@Sendable` progress/cancel closures (single-threaded test use).
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Test func applyReportsByteProgressToTotal() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.copies.count == 2)

    let progresses = Box<[SyncProgress]>([])
    let result = await engine.apply(plan, destinationVault: drive, volume: vol,
                                    progress: { p in progresses.value.append(p) })

    #expect(result.copied == 2)
    #expect(result.failed.isEmpty)

    let copying = progresses.value.filter { $0.stage == .copying }
    #expect(!copying.isEmpty)
    // bytesTotal is constant and equals the plan's copy total.
    #expect(copying.allSatisfy { $0.bytesTotal == plan.totalCopyBytes })
    // bytesDone is non-decreasing across callbacks.
    let dones = copying.map(\.bytesDone)
    #expect(dones == dones.sorted())
    // The final copying callback reaches the total.
    #expect(copying.last?.bytesDone == plan.totalCopyBytes)
    #expect(copying.last?.bytesDone == copying.last?.bytesTotal)
}

@Test func applyCancelStopsAndStillWritesManifest() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    #expect(plan.copies.count == 2)

    // Let the first file fully copy, then cancel before the second. shouldCancel is polled
    // both at the top of each file's loop AND per-chunk inside VerifiedCopy, so a call-count
    // trigger is fragile. Instead key off durable state: cancel only once the first file's
    // verified bytes have landed atomically at its dest. During file 0 it's still in a temp
    // (dest absent → false); file 1's top-of-loop check sees it present → cancels.
    let firstDest = drive.rootURL.appendingPathComponent(plan.copies[0].destRelPath)
    let result = await engine.apply(plan, destinationVault: drive, volume: vol,
                                    shouldCancel: { FileManager.default.fileExists(atPath: firstDest.path) })

    #expect(result.cancelled == true)
    #expect(result.copied == 1)
    #expect(result.copied < plan.copies.count)

    // The manifest must record the file copied before cancel, so a re-sync resumes.
    let first = plan.copies[0]
    let entries = try Manifest.read(from: drive.manifestURL)
    #expect(entries.contains { $0.path == first.destRelPath })
    #expect(FileManager.default.fileExists(
        atPath: drive.rootURL.appendingPathComponent(first.destRelPath).path))
    // The cancelled file is neither on disk nor in the manifest.
    let second = plan.copies[1]
    #expect(!entries.contains { $0.path == second.destRelPath })

    // Re-sync (no cancel) finishes the rest, skipping the already-copied file.
    let plan2 = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let resume = await engine.apply(plan2, destinationVault: drive, volume: vol)
    #expect(resume.cancelled == false)
    #expect(resume.copied == 1)
    let after = try Manifest.read(from: drive.manifestURL)
    #expect(Set(after.map(\.path)) ==
            ["Pictures/rome2022/IMG_1.jpg", "Pictures/lisbon25/IMG_2.jpg"])
}

@Test func applyClassifiesConflictNotRetryable() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let vol = FileSystemVolume(rootURL: drive.rootURL)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)

    // Put a DIFFERENT file (wrong hash) at the first dest path before applying.
    let target = plan.copies[0]
    let destURL = drive.rootURL.appendingPathComponent(target.destRelPath)
    try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("not the right bytes".utf8).write(to: destURL)

    let result = await engine.apply(plan, destinationVault: drive, volume: vol)

    #expect(result.failed.contains { $0.item == target && $0.reason == .conflict })
    #expect(result.conflicts == 1)
    #expect(result.retryableFailures.isEmpty)
    // The pre-existing file is never overwritten.
    #expect(try Data(contentsOf: destURL) == Data("not the right bytes".utf8))
}

@Test func applyBlocksOnInsufficientSpace() async throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let lib = try scannedLibrary(t); try await lib.scanAll()
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)
    let engine = SyncEngine(library: lib)
    let plan = try engine.plan(sources: lib.vaults, destinationVault: drive)
    let tiny = FakeVolume(rootURL: drive.rootURL, free: 1)
    let result = await engine.apply(plan, destinationVault: drive, volume: tiny)
    #expect(result.copied == 0)
    #expect(result.failed.count == plan.copies.count)
    #expect(!FileManager.default.fileExists(
        atPath: drive.rootURL.appendingPathComponent(plan.copies[0].destRelPath).path))
}
