import AVFoundation
import AppKit

/// The revolver-cylinder click from the mockup: a 35 ms square-wave chirp 1.8 kHz → 0.6 kHz with a
/// fast gain decay, rendered once into a PCM buffer and played through AVAudioEngine. Silent when the
/// system's "Play user interface sound effects" preference is off.
@MainActor final class RatchetSound {
    static let shared = RatchetSound()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    private init() {
        let sr = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let n = Int(sr * 0.035)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let f = t < 0.018 ? 1800 * pow(600 / 1800, t / 0.018) : 600           // exponential 1.8k → 0.6k
            phase += 2 * .pi * f / sr
            let gain = 0.05 * pow(0.0005 / 0.05, min(1, t / 0.03))                // 0.05 → 0.0005 over 30 ms
            buf.floatChannelData![0][i] = Float((sin(phase) >= 0 ? 1 : -1) * gain)
        }
        buffer = buf
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    private var uiSoundsEnabled: Bool {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.sound.uiaudio.enabled"] as? Int) != 0
    }

    func click() {
        guard uiSoundsEnabled, let buffer else { return }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }
}
