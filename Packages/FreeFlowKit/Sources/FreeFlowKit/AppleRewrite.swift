import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs `work` on its own task and returns its result, or nil when `seconds` pass first (the task is then cancelled and
/// left to finish on its own). The caller never waits past the limit. (Moved from App/WritingSupport.swift in
/// build 28 so the keyboard can use it too.)
public enum Deadline {
    public static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
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

/// What one run of Apple's model over a dictation did (AppleRewrite.write).
public struct AppleRewriteOutcome: Sendable {
    public var text: String
    /// Pieces sent to the model (one request each), written, kept as heard, and kept because time ran out.
    public var requests = 0, used = 0, kept = 0, timedOut = 0
    /// Pieces Apple refused with rateLimited, and the reset time Apple gave (iOS 27), if any.
    public var rateLimited = 0
    public var resetDate: Date?
    /// Why pieces went in as heard, in a few plain words each, without repeats.
    public var reasons: [String] = []
    /// Apple's answer for pieces the left-out safety net did not use (WritingGuard.leftOut).
    public var notUsed = ""
    public var seconds: Double = 0
}

#if canImport(FoundationModels)
/// Apple's model writes into this one field (guided generation).
@available(iOS 26.0, macOS 26.0, *)
@Generable
public struct WrittenText {
    @Guide(description: "The transcript rewritten in the requested style. Only the rewritten text.")
    public var text: String
}

/// Apple's on-device model (Foundation Models) over a dictation, used by the app and, since build 28, by the
/// keyboard. Apple limits requests from a process in the background (LanguageModelSession.GenerationError.rateLimited:
/// "only ... if your app is running in the background"); a keyboard on screen runs in the foreground app's session,
/// so a keyboard dictation is written here, in the keyboard, when the app is in the background.
@available(iOS 26.0, macOS 26.0, *)
public enum AppleRewrite {
    public static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// Available, or why not in a few words (shown in Settings, at setup and in Where it runs).
    public static var check: (available: Bool, reason: String?) {
        switch model.availability {
        case .available: return (true, nil)
        case .unavailable(let why):
            switch why {
            case .deviceNotEligible: return (false, "this device can't run Apple Intelligence")
            case .appleIntelligenceNotEnabled: return (false, "Apple Intelligence is off in the Settings app")
            case .modelNotReady: return (false, "Apple's model is still downloading")
            @unknown default: return (false, "Apple's model is not available")
            }
        }
    }

    /// Kept so its prewarmed resources stay loaded; never used to write.
    nonisolated(unsafe) private static var warmSession: LanguageModelSession?
    public static func prewarm(style: DictationStyle) {
        guard check.available else { return }
        let s = LanguageModelSession(model: model, instructions: WritingPrompt.instructions(for: style))
        s.prewarm()
        warmSession = s
    }

    /// The text written in `style`, piece by piece (WritingGuard.pieces), each piece in a new session. Any error,
    /// refusal, unusable answer or the time limit puts that piece in as heard. `os` names the system in messages.
    /// `tag` goes on the log line (e.g. "app" or "kbd").
    public static func write(_ text: String, style: DictationStyle, deadline: Date, os: String, tag: String) async -> AppleRewriteOutcome {
        let start = Date()
        var o = AppleRewriteOutcome(text: "")
        func because(_ r: String) { if !o.reasons.contains(r) { o.reasons.append(r) } }
        let instructions = WritingPrompt.instructions(for: style)
        for piece in WritingGuard.pieces(text) {
            guard piece.write else { o.text += piece.text; continue }
            let budget = deadline.timeIntervalSinceNow
            if budget < 0.05 { o.text += piece.text; o.kept += 1; o.timedOut += 1; continue }
            let message = WritingPrompt.message(piece.text)
            let words = piece.text.split(separator: " ").count
            o.requests += 1
            let t0 = Date()
            // Past the limit the request is cancelled and the piece goes in as heard.
            let result = await Deadline.run(budget) { () -> Result<String, Error> in
                do {
                    // Build 16: guided generation. The answer is one text field, so there is no room for "Sure, here is".
                    let session = LanguageModelSession(model: AppleRewrite.model, instructions: instructions)
                    let r = try await session.respond(to: message, generating: WrittenText.self, includeSchemaInPrompt: true,
                                                      options: GenerationOptions(sampling: .greedy, maximumResponseTokens: max(300, words * 4)))
                    return .success(r.content.text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch { return .failure(error) }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            switch result {
            case .some(.success(let answer)):
                if WritingGuard.leftOut(raw: piece.text, written: answer) {
                    NSLog("FFWRITE %@ piece kept-raw why=left-out words-in=%d words-out=%d ms=%.0f", tag, WritingReadout.words(piece.text), WritingReadout.words(answer), ms)
                    o.text += piece.text; o.kept += 1; because("Apple Intelligence left out words, so the text as heard was used")
                    o.notUsed += answer + " "
                } else if let why = WritingGuard.reject(raw: piece.text, written: answer) {
                    NSLog("FFWRITE %@ piece kept-raw why=%@ ms=%.0f", tag, why, ms); o.text += piece.text; o.kept += 1
                    because(why == "empty answer" ? "Apple Intelligence gave an empty answer" : "Apple Intelligence: " + why)
                } else {
                    NSLog("FFWRITE %@ piece ok words=%d ms=%.0f", tag, words, ms)
                    o.text += answer; o.used += 1
                }
            case .some(.failure(let error)):
                let limit = rateLimit(error)
                if limit.limited { o.rateLimited += 1; if let r = limit.resetDate { o.resetDate = r } }
                NSLog("FFWRITE %@ piece kept-raw ms=%.0f rate-limited=%d reset-in=%@ error=%@", tag, ms, limit.limited ? 1 : 0,
                      limit.resetDate.map { String(format: "%.0fs", $0.timeIntervalSinceNow) } ?? "-", String(describing: error))
                WriteDiagnostics.note(tag, "piece-error", ["ms": Int(ms), "rateLimited": limit.limited,
                                                           "resetIn": limit.resetDate.map { $0.timeIntervalSinceNow } ?? -1,
                                                           "error": chain(error as NSError), "plain": plain(error, os: os)])
                o.text += piece.text; o.kept += 1; because(plain(error, os: os))
            case .none:
                NSLog("FFWRITE %@ piece kept-raw why=time-limit ms=%.0f", tag, ms); o.text += piece.text; o.kept += 1; o.timedOut += 1
            }
        }
        o.seconds = Date().timeIntervalSince(start)
        if o.timedOut > 0 { because(String(format: "time limit %.1f s", deadline.timeIntervalSince(start))) }
        NSLog("FFWRITE %@ used=%d kept-raw=%d timed-out=%d requests=%d rate-limited=%d ms=%.0f words=%d style=%@", tag,
              o.used, o.kept, o.timedOut, o.requests, o.rateLimited, o.seconds * 1000, text.split(separator: " ").count, style.rawValue)
        WriteDiagnostics.note(tag, "write", ["requests": o.requests, "used": o.used, "kept": o.kept, "timedOut": o.timedOut,
                                             "rateLimited": o.rateLimited, "resetIn": o.resetDate.map { $0.timeIntervalSinceNow } ?? -1,
                                             "ms": Int(o.seconds * 1000), "words": WritingReadout.words(text), "style": style.rawValue,
                                             "reasons": o.reasons.joined(separator: "; ")])
        return o
    }

    /// Whether `error` is Apple's rate limit, and the reset time Apple gave (iOS 27 only).
    public static func rateLimit(_ error: Error) -> (limited: Bool, resetDate: Date?) {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), let e = error as? LanguageModelError {
            if case .rateLimited(let r) = e { return (true, r.resetDate) }
            return (false, nil)
        }
        #endif
        if let e = error as? LanguageModelSession.GenerationError, case .rateLimited = e { return (true, nil) }
        return (false, nil)
    }

    /// Why Apple's model gave no text for a piece, in a few plain words (the readout under the dictation).
    public static func plain(_ error: Error, os: String) -> String {
        #if compiler(>=6.4)
        // iOS 27 reports errors as LanguageModelError, with Apple's own reason (e.g. "May contain unsafe content").
        if #available(iOS 27.0, macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .refusal(let r): return "Apple Intelligence refused (" + r.debugDescription + ")"
            case .guardrailViolation(let g): return "Apple Intelligence refused (" + g.debugDescription + ")"
            case .rateLimited: return "Apple Intelligence rate-limited (\(os) limits it in the background)"
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
        case .rateLimited: return "Apple Intelligence rate-limited (\(os) limits it in the background)"
        case .concurrentRequests: return "Apple Intelligence busy"
        case .assetsUnavailable: return "Apple's model not ready"
        case .unsupportedLanguageOrLocale: return "language not supported by Apple Intelligence"
        case .exceededContextWindowSize: return "too long for Apple Intelligence"
        case .decodingFailure, .unsupportedGuide: return "Apple Intelligence answer unreadable"
        @unknown default: return "Apple Intelligence error (" + chain(error as NSError) + ")"
        }
    }

    /// An error Apple gives no case for, as its domains and codes, outermost first: e.g. the iOS 26.5 simulator's
    /// "GenerationError -1, SensitiveContentAnalysisML 15, ModelManagerError 1001" (10-30), so the line says exactly
    /// what failed.
    public static func chain(_ error: NSError) -> String {
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
