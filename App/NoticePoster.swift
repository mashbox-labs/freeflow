import FreeFlowKit
import UIKit
import UserNotifications

/// Posts the small notice after Start/Stop Free Flow runs while the app is in the background
/// (Action Button, Control Center, Lock Screen, Back Tap). It says where the text went, never the text.
@MainActor
enum NoticePoster {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(_ outcome: TriggerOutcome) {
        guard UIApplication.shared.applicationState != .active, let notice = TriggerNotice.content(for: outcome) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = "freeflow.trigger"
        content.interruptionLevel = .active
        // One notice at a time: each new one replaces the last.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "freeflow.trigger", content: content, trigger: nil))
    }

    /// A call (or Siri, or another app) cut a dictation off while Free Flow was in the background. Quiet: no sound,
    /// no lit screen during the call; it waits in Notification Center. Says what happened, never what was said.
    static func postClipSaved(_ clip: Clip) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = clip.promptTitle
        content.body = "The audio up to that point (\(clip.duration)) is saved on this device. Open Free Flow to transcribe it."
        content.threadIdentifier = "freeflow.clip"
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "freeflow.clip", content: content, trigger: nil))
    }
}
