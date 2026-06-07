import Foundation

public enum VaultRole: String, Codable, Sendable {
    case local, canonical, backup
}

public enum VaultError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case notADirectory(String)
}

/// Mirrors vault.json — vault-format-v1 §3. snake_case keys are part of the format.
public struct VaultDescriptor: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let vaultID: String
    public let role: VaultRole
    public let createdAt: String
    public let app: String

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case vaultID = "vault_id"
        case role
        case createdAt = "created_at"
        case app
    }

    public static func new(role: VaultRole) -> VaultDescriptor {
        VaultDescriptor(
            formatVersion: currentFormatVersion,
            vaultID: UUID().uuidString.lowercased(),
            role: role,
            createdAt: ISO8601Millis.string(from: Date()),
            app: "OpenPhoto/0.1")
    }
}

/// ISO-8601 UTC with milliseconds — the timestamp format used across the vault format.
public enum ISO8601Millis {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    public static func string(from date: Date) -> String { formatter.string(from: date) }
    public static func date(from string: String) -> Date? { formatter.date(from: string) }
}
