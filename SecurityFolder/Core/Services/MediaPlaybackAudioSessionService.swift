import AVFoundation

enum MediaPlaybackAudioSessionService {
    static func activateForVideoPlayback() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            print("[MediaPlaybackAudioSession] Failed to activate playback session: \(error)")
        }
    }
}
