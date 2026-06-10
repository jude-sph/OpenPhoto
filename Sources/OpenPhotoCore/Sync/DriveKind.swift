import Foundation

/// What kind of location a registered drive points at — so the UI can label it and Eject can
/// behave correctly: a real removable/network volume is *physically* unmounted (safe to unplug),
/// while a plain folder on an always-mounted disk is only "ejected" logically.
public enum DriveKind: String, Sendable {
    case removable   // USB / Thunderbolt / SD — a real ejectable volume
    case network     // a network share (not a local volume)
    case folder      // a plain folder on an always-mounted (internal) volume
    case unknown     // the path isn't reachable right now, so we can't tell

    /// True when ejecting should physically unmount the volume rather than just flag it.
    public var isRealVolume: Bool { self == .removable || self == .network }

    /// Classify the volume containing `path` via macOS volume properties. Returns `.unknown`
    /// when the path isn't reachable (e.g. the drive is unplugged).
    public static func of(path: String) -> DriveKind {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return .unknown }
        if v.volumeIsRemovable == true || v.volumeIsEjectable == true { return .removable }
        if v.volumeIsLocal == false { return .network }
        return .folder
    }
}
