import Foundation

/// Pure derivation of a camera's sidebar identity (id + display name) from raw
/// ImageCaptureCore facts. Split out of `DeviceWatcher` so it's unit-testable
/// without an `ICDevice` (which can't be constructed off real hardware).
///
/// Background: when a device first appears — especially a *locked* iPhone — ICC
/// can't yet read its serial or product name, so it reports a placeholder name
/// "LOC:<usbLocationID>". A moment later (often after unlock) the real serial and
/// name resolve. Keying identity on the serial/name therefore forks one physical
/// phone into two rows, and a stale "LOC:…" ghost leaks. The `usbLocationID` is
/// constant for the physical USB port across that whole transition, so it's the
/// stable dedup key.
public enum CameraIdentity {
    /// Stable per-connection id. Prefers `usbLocationID` (constant whether the phone
    /// is locked or unlocked) so the early placeholder add and the later resolved add
    /// collapse to one row. Falls back to serial, then name, for the (USB-less) edge.
    public static func id(usbLocationID: Int, serial: String?, name: String?) -> String {
        if usbLocationID != 0 { return "loc-\(usbLocationID)" }
        if let serial, !serial.isEmpty { return "serial-\(serial)" }
        return "name-\(name ?? "camera")"
    }

    /// Never surface ICC's "LOC:<usbLocationID>" placeholder (or an empty name) to the
    /// user — fall back to a friendly label until the real name resolves.
    public static func displayName(_ name: String?) -> String {
        let n = name ?? ""
        if n.isEmpty || n.hasPrefix("LOC:") { return "iPhone" }
        return n
    }
}
