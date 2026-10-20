import AVFoundation
import Foundation

enum Speaker: String, Codable {
    case me = "Me"
    case them = "Them"

    /// What the transcript calls this speaker: your first name, and "Others" for everyone on the call.
    var name: String {
        switch self {
        case .me: return Self.myName
        case .them: return "Others"
        }
    }

    private static let myName: String = {
        if let override = ProcessInfo.processInfo.environment["HOOT_ME"], !override.isEmpty { return override }   // product images
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Me" : first
    }()
}

struct SpeechChunk {
    let speaker: Speaker
    let start: TimeInterval   // seconds since session start
    let samples: [Float]
    let voicedRatio: Double
    var duration: TimeInterval { Double(samples.count) / kSampleRate }
}

/// One audio source over the session: keeps it aligned to the session clock,
/// writes it to a WAV file and cuts it into speech chunks at natural pauses.
final class Track {
    let speaker: Speaker
    var onChunk: ((SpeechChunk) -> Void)?

    private let sessionStart: TimeInterval   // ProcessInfo.systemUptime at session start
    private var file: AVAudioFile?
    private let lock = NSLock()

    private var written = 0                  // samples on the session timeline so far
    private var processed = 0                // samples already run through the chunker

    // Chunking state
    private var chunk: [Float] = []
    private var chunkStart = 0
    private var frameRemainder: [Float] = []
    private var trailingSilentFrames = 0
    private var voicedFrames = 0
    private var totalFrames = 0
    private var noiseFloor: Float = 0.002
    private var smoothedLevel: Float = 0

    /// Loudness right now, 0…1, for the voice bars in the island.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return smoothedLevel
    }

    private let frameSize = 480              // 30 ms
    private let minChunk = 4.0               // seconds
    private let maxChunk = 20.0
    private let pauseToCut = 0.6             // seconds of silence that ends an utterance

    init(speaker: Speaker, sessionStart: TimeInterval, fileURL: URL) {
        self.speaker = speaker
        self.sessionStart = sessionStart
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        file = try? AVAudioFile(forWriting: fileURL, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called from capture threads with freshly arrived 16 kHz samples.
    func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }

        // Sources stop delivering buffers when silent (e.g. nobody talking in the call),
        // so fill gaps with silence to keep both tracks on the same clock.
        let now = ProcessInfo.processInfo.systemUptime
        let expectedEnd = Int((now - sessionStart) * kSampleRate)
        let gap = expectedEnd - samples.count - written
        if gap > Int(kSampleRate / 2) {
            ingest([Float](repeating: 0, count: gap))
        }
        ingest(samples)
    }

    /// Flushes whatever is left and closes the file.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        emitChunk()
        file = nil   // releasing the AVAudioFile finalizes the WAV header
    }

    private func ingest(_ samples: [Float]) {
        writeToFile(samples)
        written += samples.count

        frameRemainder.append(contentsOf: samples)
        var offset = 0
        while frameRemainder.count - offset >= frameSize {
            let frame = Array(frameRemainder[offset..<offset + frameSize])
            offset += frameSize
            processFrame(frame)
        }
        frameRemainder.removeFirst(offset)
    }

    private func processFrame(_ frame: [Float]) {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let meter = min(1, max(0, (db + 50) / 40))
        smoothedLevel = meter > smoothedLevel ? meter : smoothedLevel * 0.85 + meter * 0.15

        // Adaptive noise floor: follows quiet levels quickly, loud ones slowly.
        noiseFloor = rms < noiseFloor ? noiseFloor * 0.9 + rms * 0.1 : noiseFloor * 0.999 + rms * 0.001
        let threshold = max(0.008, noiseFloor * 3)
        let voiced = rms > threshold

        let frameStart = processed
        processed += frame.count

        if chunk.isEmpty {
            // Don't start a chunk on silence; just slide the start forward.
            guard voiced else { return }
            chunkStart = frameStart
        }

        chunk.append(contentsOf: frame)
        totalFrames += 1
        if voiced { voicedFrames += 1; trailingSilentFrames = 0 } else { trailingSilentFrames += 1 }

        let length = Double(chunk.count) / kSampleRate
        let silence = Double(trailingSilentFrames * frameSize) / kSampleRate
        if (length >= minChunk && silence >= pauseToCut) || length >= maxChunk {
            emitChunk()
        } else if length < minChunk && silence >= 1.5 {
            // A short blip followed by a long pause: emit it if it had real speech, else drop.
            if voicedFrames >= 10 { emitChunk() } else { resetChunk() }
        }
    }

    private func emitChunk() {
        defer { resetChunk() }
        guard voicedFrames >= 8, totalFrames > 0 else { return }   // < ~0.25 s of speech: ignore
        let result = SpeechChunk(speaker: speaker,
                                 start: Double(chunkStart) / kSampleRate,
                                 samples: chunk,
                                 voicedRatio: Double(voicedFrames) / Double(totalFrames))
        onChunk?(result)
    }

    private func resetChunk() {
        chunk.removeAll(keepingCapacity: true)
        voicedFrames = 0
        totalFrames = 0
        trailingSilentFrames = 0
    }

    private func writeToFile(_ samples: [Float]) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buffer)
    }
}
