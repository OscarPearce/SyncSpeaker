import AVFoundation

/// Audio files every phone can play. A track's id is its file name, so each
/// phone needs a file with the same name.
///
/// Sources:
/// - A generated click track (always present; the best way to hear sync errors).
/// - Files in the app's Documents folder. Info.plist enables file sharing, so
///   you can drop files in from the Files app or from Finder on a Mac.
enum LocalLibrary {
    static let clickTrackID = "click-track-120bpm.wav"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func allTracks() -> [TrackSource] {
        ensureClickTrack()
        let exts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac"]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        return files
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0 == clickTrackID ? true : ($1 == clickTrackID ? false : $0 < $1) }
            .map { name -> TrackSource in
                let title = name == clickTrackID ? "Click track (120 bpm)" : (name as NSString).deletingPathExtension
                return .local(id: name, title: title)
            }
    }

    static func url(forID id: String) -> URL? {
        if id == clickTrackID { ensureClickTrack() }
        let url = documents.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 3 minutes of 120 bpm clicks, accented every 4th beat. Two speakers that
    /// are out of sync by more than ~10 ms sound like a "flam" (a double hit).
    static func ensureClickTrack() {
        let url = documents.appendingPathComponent(clickTrackID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let sr = 44_100.0
        let seconds = 180.0
        let total = Int(sr * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))
        else { return }
        buffer.frameLength = AVAudioFrameCount(total)
        let out = buffer.floatChannelData![0]
        for i in 0..<total { out[i] = 0 }

        let beat = Int(sr * 0.5)
        let clickLen = Int(sr * 0.02)
        var b = 0
        var start = 0
        while start + clickLen < total {
            let accent = b % 4 == 0
            let freq = accent ? 2_000.0 : 1_200.0
            let amp: Float = accent ? 0.8 : 0.5
            for i in 0..<clickLen {
                let t = Double(i) / sr
                out[start + i] = amp * Float(sin(2 * .pi * freq * t) * exp(-t * 250))
            }
            b += 1
            start += beat
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            print("Couldn't write click track: \(error)")
        }
    }
}
