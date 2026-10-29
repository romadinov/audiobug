import AVFoundation
import Foundation

/// Long-form spoken audio: AirPlay 2 / HomePod aware on the iPhone; Bluetooth headphones on the Watch,
/// where activation shows the system route picker when no headphones are connected.
enum AudioSession {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        } catch {
            try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        }
    }

    /// Returns false when playback cannot start (on the Watch: the listener dismissed the headphone picker).
    static func activate() async -> Bool {
        #if os(watchOS)
        do { return try await AVAudioSession.sharedInstance().activate(options: []) } catch { return false }
        #else
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            return false
        }
        #endif
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The name of the current output, e.g. "AirPods Pro" or "Speaker".
    static var outputName: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.map(\.portName).joined(separator: ", ")
    }
}
