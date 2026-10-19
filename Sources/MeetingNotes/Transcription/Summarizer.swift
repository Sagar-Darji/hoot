import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes a meeting summary, decisions and action items with Apple Intelligence's on-device model.
/// Nothing leaves the Mac. Long meetings are summarised in parts, then the parts are combined,
/// because the on-device model only reads a few thousand words at a time.
enum Summarizer {
    enum SummaryError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let why): return why }
        }
    }

    /// nil when summaries can be made; otherwise a short reason to show the user.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings to get meeting summaries."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading — summaries will work once it's ready."
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence summaries."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Meeting summaries need macOS 26 or later."
    }

    static func summarize(_ lines: [TranscriptLine]) async throws -> String {
        if let reason = unavailableReason { throw SummaryError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let transcript = lines.map { "[\(Recorder.clock($0.start))] \($0.speaker.name): \($0.text)" }
            let parts = chunk(transcript, maxCharacters: 6_000)
            if parts.count == 1 { return try await final(from: parts[0]) }
            var notes: [String] = []
            for (i, part) in parts.enumerated() {
                let session = LanguageModelSession(instructions: """
                    You take concise notes on part of a meeting transcript. Keep names, numbers, dates, \
                    decisions and commitments exactly as said. Use short bullet points. No preamble.
                    """)
                let r = try await session.respond(to: "Part \(i + 1) of \(parts.count):\n\n\(part)")
                notes.append(r.content)
            }
            return try await final(from: notes.joined(separator: "\n\n"), fromNotes: true)
        }
        #endif
        throw SummaryError.unavailable("Meeting summaries need macOS 26 or later.")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func final(from text: String, fromNotes: Bool = false) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You write meeting notes in Markdown for the person who recorded the meeting \
            ("\(Speaker.me.name)"; everyone else is "\(Speaker.them.name)"). Be brief and factual; never invent \
            details. Use exactly these sections, leaving out any that would be empty:
            ## Summary
            2–4 sentences.
            ## Decisions
            - bullet per decision
            ## Action Items
            - [ ] Who: what (by when, if said)
            ## Open Questions
            - bullet per unresolved question
            """)
        let source = fromNotes ? "Notes taken during the meeting" : "Meeting transcript"
        return try await session.respond(to: "\(source):\n\n\(text)").content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    private static func chunk(_ lines: [String], maxCharacters: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count > maxCharacters {
                parts.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// Answers questions about the meeting in progress with the on-device model, streaming as it writes.
enum MeetingAI {
    static let quickPrompts: [(label: String, symbol: String, prompt: String)] = [
        ("Catch me up", "arrow.uturn.backward", "Catch me up: summarize the last few minutes in 3 short bullets."),
        ("What should I say?", "text.bubble", "Suggest 2–3 short, natural things I could say next, based on where the conversation is."),
        ("Action items", "checklist", "List the action items and commitments so far as '- [ ] Who: what'."),
        ("Explain that", "lightbulb", "Explain the last point the others made in simple terms, in 2–3 sentences."),
    ]

    /// Yields the answer so far each time the model writes more.
    static func ask(_ question: String, transcript: [TranscriptLine], notes: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Summarizer.unavailableReason { throw Summarizer.SummaryError.unavailable(reason) }
                    #if canImport(FoundationModels)
                    if #available(macOS 26.0, *) {
                        // The on-device model reads a few thousand words; keep the most recent part of the meeting.
                        var convo = transcript.map { "[\(Recorder.clock($0.start))] \($0.speaker.name): \($0.text)" }
                            .joined(separator: "\n")
                        if convo.count > 7_000 { convo = "…" + String(convo.suffix(7_000)) }
                        let cue = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        let session = LanguageModelSession(instructions: """
                            You are a discreet assistant helping \(Speaker.me.name) during a live meeting. \
                            Answer only from the transcript and notes given; if they don't contain the answer, say so briefly. \
                            Be very short and scannable — the user is reading while talking. Use Markdown bullets where useful.
                            """)
                        let prompt = """
                            Meeting transcript so far (\(Speaker.me.name) is me, "\(Speaker.them.name)" is everyone else):
                            \(convo.isEmpty ? "(nothing transcribed yet)" : convo)
                            \(cue.isEmpty ? "" : "\nMy speaker notes:\n\(cue.prefix(1_500))\n")
                            Question: \(question)
                            """
                        for try await partial in session.streamResponse(to: prompt) {
                            continuation.yield(partial.content)
                        }
                        continuation.finish()
                        return
                    }
                    #endif
                    throw Summarizer.SummaryError.unavailable("Needs macOS 26 or later.")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
