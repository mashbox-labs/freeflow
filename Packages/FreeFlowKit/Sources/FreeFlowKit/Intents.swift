#if os(iOS)
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import AppIntents
import Foundation

/// What the app does when a control, the Action Button, Back Tap or Siri runs an intent.
/// The app sets these at launch. In the widget extension they stay nil.
@MainActor
public enum FFActions {
    /// One press of Start/Stop Free Flow. The flag is true once the app has been brought to the foreground for it.
    public static var toggleDictation: ((_ inForeground: Bool) async -> TriggerOutcome)?
    public static var finishDictation: (() async -> String)?
    public static var startSession: (() async -> String)?
}

/// Start/Stop Free Flow: one press starts listening, the next stops it. With the Free Flow keyboard on screen the
/// text is typed at the cursor; otherwise it is copied and a small notice says so.
/// The Action Button, the Control Center and Lock Screen controls, Siri and shortcuts (so Back Tap) all run this.
/// While the mic session is warm it works without opening the app. With no warm session iOS will not turn the
/// microphone on from the background, so on iOS 26 the first press opens Free Flow and starts listening there.
public struct ToggleDictationIntent: AudioRecordingIntent {
    public static let title: LocalizedStringResource = "Start/Stop Free Flow"
    public static let description = IntentDescription("Start dictating from anywhere; run it again to stop. With the Free Flow keyboard up, the text is typed at your cursor. Otherwise it is copied so you can paste it.")

    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    /// Build 32 (device test of build 31): the Control (Control Center, Lock Screen, Action Button > Controls)
    /// works; run as a Shortcuts-app action it did not. Not listed in the Shortcuts app, Siri or Spotlight; the
    /// Control still runs it.
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        SharedSession.lastTrigger = Date()
        guard let toggle = FFActions.toggleDictation else {
            return .result(value: "", dialog: "Open Free Flow once to finish setting it up.")
        }
        var outcome = await toggle(false)
        if outcome == .needsApp, #available(iOS 26.0, *) {
            try await continueInForeground(nil, alwaysConfirm: false)
            outcome = await toggle(true)
        }
        return .result(value: outcome.value, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

/// The Stop button in the Live Activity: finishes a dictation in progress, otherwise turns the mic off.
public struct FinishDictationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Free Flow"
    public static let description = IntentDescription("Finish the dictation in progress, or turn the microphone off.")
    public static let openAppWhenRun = false
    /// Build 31: only the Live Activity's Stop button runs it; not listed in Shortcuts, Siri or the Action button.
    public static let isDiscoverable = false
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = await FFActions.finishDictation?()
        return .result()
    }
}

/// Turn the microphone session on so the keyboard can dictate without opening the app.
/// Build 31: no longer offered anywhere (Start/Stop is the one action); kept so a shortcut someone already
/// made still runs. The in-app session is unchanged.
public struct StartSessionIntent: AudioRecordingIntent {
    public static let title: LocalizedStringResource = "Start Free Flow session"
    public static let description = IntentDescription("Keep the microphone ready so the Free Flow keyboard can dictate without switching apps.")
    public static let openAppWhenRun = false
    public static let isDiscoverable = false
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedSession.lastTrigger = Date()
        guard let action = FFActions.startSession else {
            return .result(dialog: "Open Free Flow once to finish setting it up.")
        }
        return .result(dialog: IntentDialog(stringLiteral: await action()))
    }
}

public struct FreeFlowIntentsPackage: AppIntentsPackage {}

#if !targetEnvironment(macCatalyst)   // no Live Activities on the Mac
/// The Live Activity shown while Free Flow listens (Lock Screen and Dynamic Island).
public struct DictationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: String
        public var detail: String
        public var startedAt: Date
        /// When the armed window ends and the mic turns off by itself.
        public var endsAt: Date?
        public init(phase: String, detail: String, startedAt: Date, endsAt: Date? = nil) {
            self.phase = phase
            self.detail = detail
            self.startedAt = startedAt
            self.endsAt = endsAt
        }
    }
    public var modelName: String
    public init(modelName: String) { self.modelName = modelName }
}
#endif
#endif
