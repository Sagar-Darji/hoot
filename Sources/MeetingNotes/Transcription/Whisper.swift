import Foundation

enum WhisperError: LocalizedError {
    case binaryMissing, modelMissing(String), serverDidNotStart, badResponse(String), downloadFailed(String)
    var errorDescription: String? {
        switch self {
        case .binaryMissing: return "Hoot's speech engine is missing — please reinstall Hoot."
        case .downloadFailed(let why): return "Couldn't download the speech model (\(why)). Check your internet and reopen Hoot."
        case .modelMissing(let p): return "Whisper model missing at \(p)"
        case .serverDidNotStart: return "Whisper server failed to start."
        case .badResponse(let s): return "Whisper error: \(s)"
        }
    }
}

/// Runs a local whisper.cpp server so the model stays loaded between chunks.
final class WhisperServer {
    static let port = 8178
    static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingNotes", isDirectory: true)
    }

    /// First model found wins, so dropping a different ggml model into the folder switches models.
    static var modelURL: URL? {
        let dir = supportDir.appendingPathComponent("models")
        let preferred = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin",
                         "ggml-small.bin", "ggml-base.bin", "ggml-base.en.bin"]
        for name in preferred {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let any = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
        return any
    }

    private var process: Process?

    /// Downloaded on first launch so the app itself stays small enough to share.
    static let defaultModelName = "ggml-large-v3-turbo-q5_0.bin"
    static let defaultModelSource = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    /// The engine shipped inside Hoot.app; a Homebrew install is only a fallback for development builds.
    static var binaryPath: String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("whisper/whisper-server").path
        return [bundled, "/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(language: String, onDownload: ((Double) -> Void)? = nil) async throws {
        if await isHealthy() {
            if process?.isRunning == true { return }   // ours, already up
            // Left behind by a crash or a force-quit: replace it, so we own (and can later unload) the engine.
            Self.stopStrays()
            for _ in 0..<30 where await isHealthy() { try await Task.sleep(nanoseconds: 100_000_000) }
        }

        guard let binary = Self.binaryPath else { throw WhisperError.binaryMissing }
        let model: URL
        if let existing = Self.modelURL {
            model = existing
        } else {
            model = try await Self.downloadModel(progress: onDownload ?? { _ in })
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model.path,
                       "--host", "127.0.0.1", "--port", String(Self.port),
                       "-l", language,
                       "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount / 2)),
                       "-sns",            // suppress non-speech tokens like [Music]
                       "-nth", "0.6"]
        let log = Self.supportDir.appendingPathComponent("whisper-server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        process = p

        // Model load takes a few seconds the first time.
        for _ in 0..<120 {
            if await isHealthy() { return }
            if !p.isRunning { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WhisperError.serverDidNotStart
    }

    /// Fetches the speech model (~550 MB) into Application Support, reporting progress 0…1.
    static func downloadModel(progress: @escaping (Double) -> Void) async throws -> URL {
        let dir = supportDir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(defaultModelName)
        let delegate = DownloadProgress(progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (temp, response) = try await session.download(from: defaultModelSource)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int,
                  size > 100_000_000 else {
                throw WhisperError.downloadFailed("unexpected response")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        } catch let error as WhisperError {
            throw error
        } catch {
            throw WhisperError.downloadFailed(error.localizedDescription)
        }
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    /// Ends any speech engine on Hoot's port that this process didn't start.
    static func stopStrays() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? p.run()
        p.waitUntilExit()
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func isHealthy() async -> Bool {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Transcribes 16 kHz mono samples and returns plain text.
    func transcribe(_ samples: [Float], prompt: String?) async throws -> String {
        let boundary = "----meetingnotes\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("temperature", "0.0")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(WAV.encode(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: Self.baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)

        struct Result: Decodable { let text: String?; let error: String? }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw WhisperError.badResponse(String(data: data, encoding: .utf8) ?? "unreadable")
        }
        if let error = result.error { throw WhisperError.badResponse(error) }
        return result.text ?? ""
    }
}

enum WAV {
    /// 16-bit PCM mono WAV.
    static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        let rate = UInt32(kSampleRate)
        let dataSize = UInt32(samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(dataSize)
        data.reserveCapacity(data.count + samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            u16(UInt16(bitPattern: v))
        }
        return data
    }
}
