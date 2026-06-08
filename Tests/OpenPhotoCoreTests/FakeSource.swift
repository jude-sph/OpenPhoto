import Foundation
import CoreGraphics
@testable import OpenPhotoCore

/// Controllable in-memory ImportSource for engine tests.
final class FakeSource: ImportSource, @unchecked Sendable {
    let sourceKey: String
    let displayName = "Fake Device"
    private let payloads: [String: Data]
    private let listed: [ImportItem]
    /// Set these to inject failures:
    var failFetchIDs: Set<String> = []
    var failDeleteIDs: Set<String> = []
    private(set) var deletedIDs: [String] = []

    init(sourceKey: String, items: [(ImportItem, Data)]) {
        self.sourceKey = sourceKey
        self.listed = items.map(\.0)
        self.payloads = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
    }

    func enumerateItems() async throws -> [ImportItem] { listed }

    func fetch(_ item: ImportItem, to url: URL) async throws {
        if failFetchIDs.contains(item.id) {
            throw CocoaError(.fileReadUnknown)
        }
        try payloads[item.id]!.write(to: url)
    }

    func delete(_ items: [ImportItem]) async throws -> [DeleteResult] {
        items.map { i in
            if failDeleteIDs.contains(i.id) {
                return DeleteResult(itemID: i.id, error: "injected failure")
            }
            deletedIDs.append(i.id)
            return DeleteResult(itemID: i.id, error: nil)
        }
    }

    func thumbnail(_ item: ImportItem, maxPixel: Int) async -> CGImage? { nil }
}
