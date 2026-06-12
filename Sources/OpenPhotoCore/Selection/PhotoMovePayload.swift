import Foundation

/// Drag payload for moving photos onto the folder tree. Folder rows accept String
/// drops (folder paths) — photo drags share that one channel behind a marker prefix
/// + JSON id list, so a single `dropDestination(for: String.self)` serves both.
public enum PhotoMovePayload {
    private static let marker = "photos:"

    public static func encode(_ instanceIDs: [String]) -> String {
        let json = (try? JSONEncoder().encode(instanceIDs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return marker + json
    }

    /// Nil when `string` isn't a photo payload (i.e. it's a plain folder path).
    public static func decode(_ string: String) -> [String]? {
        guard string.hasPrefix(marker) else { return nil }
        return try? JSONDecoder().decode([String].self,
                                         from: Data(string.dropFirst(marker.count).utf8))
    }
}
