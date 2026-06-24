import Foundation

/// Human-readable byte/speed/duration formatting shared by the sync sheet and the sidebar chip.
/// Free functions (not methods) so any view can use them without plumbing a formatter through.

/// "1.2 GB" — file-style byte count.
func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// "84 MB/s" — file-style byte count of a per-second rate, suffixed with "/s".
func speedString(_ bytesPerSec: Double) -> String {
    let n = Int64(max(0, bytesPerSec))
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .file) + "/s"
}

/// "14 min" — abbreviated duration. One shared formatter (DateComponentsFormatter is reusable).
private let etaFormatter: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.allowedUnits = [.hour, .minute, .second]
    f.maximumUnitCount = 2
    return f
}()

func etaString(_ seconds: Double) -> String {
    let s = max(0, seconds)
    return etaFormatter.string(from: s) ?? "—"
}
