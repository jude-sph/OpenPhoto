import Foundation

/// Throwaway directory per test, auto-cleaned.
struct TestDirs {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openphoto-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func sub(_ name: String) throws -> URL {
        let u = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Write a file (creating intermediate dirs) and return its URL.
    @discardableResult
    func file(_ relPath: String, _ contents: Data) throws -> URL {
        let u = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u)
        return u
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
