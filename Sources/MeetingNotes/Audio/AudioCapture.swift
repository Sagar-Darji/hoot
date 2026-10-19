import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Everything downstream works on 16 kHz mono Float32 — what Whisper wants.
let kSampleRate: Double = 16_000

/// Converts arbitrary PCM buffers into 16 kHz mono float samples.
final class MonoResampler {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kSampleRate,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0

    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return [] }

        // Downmix by taking channel 0. With voice processing enabled the mic node can expose
        // several channels; channel 0 is the processed (echo-cancelled) voice.
        let rate = buffer.format.sampleRate
        if rate == kSampleRate {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }

        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: 1, interleaved: false)!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        mono.frameLength = AVAudioFrameCount(frames)
        mono.floatChannelData![0].update(from: channels[0], count: frames)

        if converter == nil || sourceRate != rate {
            converter = AVAudioConverter(from: monoFormat, to: target)
            sourceRate = rate
        }
        guard let converter else { return [] }

        let capacity = AVAudioFrameCount(Double(frames) * kSampleRate / rate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        if error != nil { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// Captures the microphone ("Me").
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()
    var onSamples: (([Float]) -> Void)?
    var onRestartFailed: ((Error) -> Void)?
    private var echoCancellation = false
    private var configObserver: NSObjectProtocol?

    func start(echoCancellation: Bool) throws {
        self.echoCancellation = echoCancellation
        try configureAndStart()
        // Plugging in / removing headphones or AirPods reconfigures the engine and stops it.
        // Without this, your side of the call would silently stop being recorded.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    private func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try configureAndStart()
        } catch {
            // Some devices can't do voice processing; keep recording without it rather than not at all.
            if echoCancellation {
                echoCancellation = false
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                if (try? configureAndStart()) != nil { return }
            }
            onRestartFailed?(error)
        }
    }

    private func configureAndStart() throws {
        let input = engine.inputNode
        if echoCancellation {
            // Apple's voice processing removes what the speakers play (the other people)
            // from the mic signal, so their words don't show up twice as "Me".
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.process(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for system audio capture."
        }
    }
}

/// Captures everything the Mac plays ("Them") via ScreenCaptureKit — works with any call app.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "meetingnotes.systemaudio")
    private let resampler = MonoResampler()
    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(kSampleRate)
        config.channelCount = 1
        // We only want audio; keep the video side as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Attach a screen output too, otherwise SCK logs "dropping frame" warnings constantly.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.process(pcm)
        if !samples.isEmpty { onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                         channels: asbd.mChannelsPerFrame) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
