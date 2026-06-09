import Foundation

/// Append-only sync-log writer (format §9, informative). One JSON object per line.
public enum SyncLog {
    public static func append(event: String, summary: String, counterparty: String, to url: URL) {
        let line: [String: Any] = ["event": event,
                                   "at": ISO8601Millis.string(from: Date()),
                                   "counterparty_vault_id": counterparty,
                                   "summary": summary]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else { return }
        var existing = (try? Data(contentsOf: url)) ?? Data()
        existing.append(data); existing.append(0x0A)
        try? AtomicFile.write(existing, to: url)
    }
}
