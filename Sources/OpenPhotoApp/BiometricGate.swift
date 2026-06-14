import Foundation
import LocalAuthentication

/// Touch ID (with automatic device-password fallback) for unlocking hidden folders. Uses
/// `.deviceOwnerAuthentication`, so it works on Macs without Touch ID (password) and in our ad-hoc-
/// signed bundle — no entitlement or Info.plist usage string needed on macOS.
enum BiometricGate {
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}
