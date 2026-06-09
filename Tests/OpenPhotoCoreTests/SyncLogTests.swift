import Testing
import Foundation
@testable import OpenPhotoCore

@Test func syncLogAppendsOneJSONLineWithRequiredKeys() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let drive = try Vault.openOrCreate(at: try t.sub("drive"), role: .canonical)

    SyncLog.append(event: "delete", summary: "3 propagated to drive bin",
                   counterparty: "mac-1", to: drive.syncLogURL)
    SyncLog.append(event: "sync", summary: "ok", counterparty: "", to: drive.syncLogURL)

    let lines = (try Data(contentsOf: drive.syncLogURL))
        .split(separator: 0x0A).filter { !$0.isEmpty }
    #expect(lines.count == 2)
    let first = try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any]
    #expect(first?["event"] as? String == "delete")
    #expect(first?["counterparty_vault_id"] as? String == "mac-1")
    #expect(first?["summary"] as? String == "3 propagated to drive bin")
    #expect((first?["at"] as? String)?.isEmpty == false)
}
