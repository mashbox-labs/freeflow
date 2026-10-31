#if canImport(FoundationModels)
import FoundationModels
#endif
import FreeFlowKit
import Foundation

/// The writing layer on the Mac, as on iPhone (build 18: LFM3 is dropped; Apple Intelligence writes, and it is
/// optional). Apple's on-device model (permissive content-transformation guardrails, one guided text field, greedy)
/// when the person has "Clean up with Apple Intelligence" on and the machine can run it; otherwise Parakeet's words, with
/// the dictionary, go in as heard, and the readout says why: switched off, macOS before 26, the machine not eligible,
/// Apple Intelligence off in System Settings, or Apple's model still downloading. Same prompts (WritingPrompt), same
/// pieces, the same WritingGuard and the same time limit for the whole step (WritingBudget): any error, refusal,
/// unusable answer or the limit puts the heard text in for that piece, never edited by a rule. Nothing leaves the Mac.
enum MacWriter {
    static func write(_ text: String, style: DictationStyle) async -> (text: String, readout: WritingReadout) {
        guard !text.isEmpty else { return raw(text, note: "nothing was heard") }
        if WriterChoice.resolved == .off { return raw(text, note: "Apple Intelligence cleanup is off") }
        let budget = WritingBudget.seconds(words: WritingReadout.words(text))
        let deadline = Date().addingTimeInterval(budget)
        if let r = await Deadline.run(budget + 0.25, { await appleOrRaw(text, style: style, deadline: deadline) }) { return r }
        return raw(text, note: String(format: "time limit %.1f s", budget))
    }

    /// Called when listening starts: Apple's model prewarmed while the person talks (nothing when the switch is off).
    @MainActor static func prepare() {
        guard WriterChoice.resolved != .off else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { Task.detached(priority: .utility) { MacAppleWriter.prewarm() } }
        #endif
    }

    /// Whether Apple's model can run on this machine, and if not, why in a few words.
    static var check: (available: Bool, reason: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return MacAppleWriter.check }
        #endif
        return (false, "needs macOS 26 or later")
    }
    static var appleAvailable: Bool { check.available }

    static func appleOrRaw(_ text: String, style: DictationStyle, deadline: Date) async -> (text: String, readout: WritingReadout) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let c = MacAppleWriter.check
            if c.available { return await MacAppleWriter.write(text, style: style, deadline: deadline) }
            return raw(text, note: c.reason ?? "Apple Intelligence not available")
        }
        #endif
        return raw(text, note: "Apple Intelligence needs macOS 26")
    }

    static func raw(_ text: String, note: String) -> (text: String, readout: WritingReadout) {
        let n = WritingReadout.words(text)
        return (text, WritingReadout(model: "None", runtime: "raw text", background: false, wordsIn: n, wordsOut: n,
                                     seconds: 0, note: note))
    }
}

/// Runs `work` on its own task and returns its result, or nil when `seconds` pass first (the task is then cancelled and
/// left to finish on its own). The caller never waits past the limit. The iPhone app's Deadline (App/WritingSupport.swift).
enum Deadline {
    static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        guard seconds > 0 else { return nil }
        let first = FirstResult<T>()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            first.wait(c)
            let task = Task.detached(priority: .userInitiated) { first.finish(await work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if first.finish(nil) { task.cancel() }
            }
        }
    }
}

private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    func wait(_ c: CheckedContinuation<T?, Never>) { lock.lock(); continuation = c; lock.unlock() }
    /// Resumes the caller with `value` if nothing did yet; true when this call did.
    @discardableResult func finish(_ value: T?) -> Bool {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}

#if canImport(FoundationModels)
/// Apple's model writes into this one field (guided generation), as on iPhone.
@available(macOS 26.0, *)
@Generable
struct MacWrittenText {
    @Guide(description: "The transcript rewritten in the requested style. Only the rewritten text.")
    var text: String
}

@available(macOS 26.0, *)
enum MacAppleWriter {
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    static var check: (available: Bool, reason: String?) {
        switch model.availability {
        case .available: return (true, nil)
        case .unavailable(let why):
            switch why {
            case .deviceNotEligible: return (false, "this Mac can't run Apple Intelligence")
            case .appleIntelligenceNotEnabled: return (false, "Apple Intelligence is off in System Settings")
            case .modelNotReady: return (false, "Apple's model is still downloading")
            @unknown default: return (false, "Apple's model is not available")
            }
        }
    }

    /// Kept so its prewarmed resources stay loaded; never used to write.
    nonisolated(unsafe) private static var warmSession: LanguageModelSession?
    static func prewarm() {
        guard check.available else { return }
        let style = DictationStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .formal   // MacDictation.style
        let s = LanguageModelSession(model: model, instructions: WritingPrompt.instructions(for: style))
        s.prewarm()
        warmSession = s
    }

    static func write(_ text: String, style: DictationStyle, deadline: Date) async -> (text: String, readout: WritingReadout) {
        let start = Date()
        var out = "", used = 0, kept = 0, timedOut = 0
        var reasons: [String] = []
        func because(_ r: String) { if !reasons.contains(r) { reasons.append(r) } }
        let instructions = WritingPrompt.instructions(for: style)
        for piece in WritingGuard.pieces(text) {
            guard piece.write else { out += piece.text; continue }
            let budget = deadline.timeIntervalSinceNow
            if budget < 0.05 { out += piece.text; kept += 1; timedOut += 1; continue }
            let message = WritingPrompt.message(piece.text)
            let words = piece.text.split(separator: " ").count
            // Past the limit the request is cancelled and the piece goes in as heard.
            let result = await Deadline.run(budget) { () -> Result<String, Error> in
                do {
                    let session = LanguageModelSession(model: MacAppleWriter.model, instructions: instructions)
                    let r = try await session.respond(to: message, generating: MacWrittenText.self, includeSchemaInPrompt: true,
                                                      options: GenerationOptions(sampling: .greedy, maximumResponseTokens: max(300, words * 4)))
                    return .success(r.content.text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch { return .failure(error) }
            }
            switch result {
            case .some(.success(let answer)):
                if let why = WritingGuard.reject(raw: piece.text, written: answer) {
                    out += piece.text; kept += 1
                    because(why == "empty answer" ? "Apple Intelligence gave an empty answer" : "Apple Intelligence: " + why)
                } else { out += answer; used += 1 }
            case .some(.failure(let error)):
                out += piece.text; kept += 1; because(plain(error))
            case .none:
                out += piece.text; kept += 1; timedOut += 1
            }
        }
        if timedOut > 0 { because(String(format: "time limit %.1f s", deadline.timeIntervalSince(start))) }
        return (out, WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: false,
                                    wordsIn: WritingReadout.words(text), wordsOut: WritingReadout.words(out),
                                    seconds: Date().timeIntervalSince(start), keptRaw: kept,
                                    note: reasons.isEmpty ? nil : reasons.joined(separator: ", "), used: used))
    }

    /// Why Apple's model gave no text for a piece, in a few plain words (the readout).
    static func plain(_ error: Error) -> String {
        #if compiler(>=6.4)
        // macOS 27 reports errors as LanguageModelError, with Apple's own reason (e.g. "May contain sensitive content").
        if #available(macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .refusal(let r): return "Apple Intelligence refused (" + r.debugDescription + ")"
            case .guardrailViolation(let g): return "Apple Intelligence refused (" + g.debugDescription + ")"
            case .rateLimited: return "Apple Intelligence rate-limited"
            case .contextSizeExceeded: return "too long for Apple Intelligence"
            case .unsupportedLanguageOrLocale: return "language not supported by Apple Intelligence"
            case .timeout: return "Apple Intelligence timed out"
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                return "Apple Intelligence can't take this request"
            @unknown default: return "Apple Intelligence error (" + chain(error as NSError) + ")"
            }
        }
        #endif
        guard let e = error as? LanguageModelSession.GenerationError else { return "Apple Intelligence error (" + chain(error as NSError) + ")" }
        switch e {
        case .refusal, .guardrailViolation: return "Apple Intelligence refused"
        case .rateLimited: return "Apple Intelligence rate-limited"
        case .concurrentRequests: return "Apple Intelligence busy"
        case .assetsUnavailable: return "Apple's model not ready"
        case .unsupportedLanguageOrLocale: return "language not supported by Apple Intelligence"
        case .exceededContextWindowSize: return "too long for Apple Intelligence"
        case .decodingFailure, .unsupportedGuide: return "Apple Intelligence answer unreadable"
        @unknown default: return "Apple Intelligence error (" + chain(error as NSError) + ")"
        }
    }

    /// An error Apple gives no case for, as its domains and codes, outermost first.
    static func chain(_ error: NSError) -> String {
        var parts: [String] = [], queue = [error]
        while !queue.isEmpty, parts.count < 4 {
            let e = queue.removeFirst()
            let p = (e.domain.split(separator: ".").last.map(String.init) ?? e.domain) + " \(e.code)"
            if !parts.contains(p) { parts.append(p) }
            if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(u) }
            if let us = e.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { queue.append(contentsOf: us) }
        }
        return parts.joined(separator: ", ")
    }
}
#endif
