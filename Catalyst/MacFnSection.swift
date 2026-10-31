#if targetEnvironment(macCatalyst)
import FreeFlowKit
import SwiftUI

/// Settings on the Mac, in place of the iPhone's keyboard and session sections: fn, its permission and the mic.
struct MacFnSection: View {
    @ObservedObject private var mac = MacHost.shared
    @AppStorage(MacMic.key) private var micMinutes = MacMic.defaultMinutes

    var body: some View {
        Section("fn key") {
            Label("Hold fn to dictate", systemImage: "globe").badge(mac.accessibility ? "On" : "Off")
            if !mac.accessibility {
                Button("Turn on Accessibility") { MacHost.shared.askAccessibility() }
                Button("Open Accessibility settings") { MacHost.shared.openSettings("accessibility") }
            }
            if let note = FnKeySetting.note {
                Text(note).font(FFFont.text(14)).foregroundStyle(Palette.warn)
                Button("Open Keyboard settings") { MacHost.shared.openSettings("keyboard") }
            }
            LabeledContent("Microphone", value: mac.micName.isEmpty ? "None found" : mac.micName)
            Button("Sound settings") { MacHost.shared.openSettings("sound") }
        }
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .onAppear { MacHost.shared.refresh() }
        // Build 23 (F2): the Session picker on the Mac.
        Section("Session") {
            Picker("Mic after fn", selection: $micMinutes) {
                ForEach(MacMic.choices, id: \.self) { Text(MacMic.label($0)).tag($0) }
            }
            .accessibilityIdentifier("macMicMinutes")
            if let at = SharedSession.lastEndAt, !SharedSession.lastEnd.isEmpty {
                Text("Last time the mic turned off: \(SharedSession.lastEnd), \(at.formatted(date: .abbreviated, time: .shortened)).")
                    .font(FFFont.text(13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        Section { EmptyView() } footer: {
            Text("Off right after each dictation: the mic turns on when you press fn and off once your words are in, so the orange dot shows only while you talk. A longer time keeps it on between dictations.")
                .font(FFFont.text(14))
        }
        .listSectionSeparator(.hidden)
        Section { EmptyView() } footer: {
            Text("Hold fn and talk, let go to type it. Press fn twice for hands-free, then fn again to stop. Esc cancels. Free Flow records from the Mac's default input; change it in Sound settings.")
                .font(FFFont.text(14))
        }
        .listSectionSeparator(.hidden)
    }
}

/// The Dictate tab's card on the Mac, where the iPhone has its session card: how fn works and whether it can.
struct MacFnCard: View {
    @ObservedObject private var mac = MacHost.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("fn key").ffEyebrow()
                Spacer()
                Circle().fill(mac.accessibility ? Palette.ok : Palette.faint).frame(width: 8, height: 8)
                Text(mac.accessibility ? "On" : "Off").font(FFFont.text(14, .bold)).accessibilityIdentifier("fnState")
            }
            Text("Hold fn in any app and talk, then let go: your words go in where your cursor is. Press fn twice for hands-free, then fn again to stop. Esc cancels. macOS shows the orange dot in the menu bar while Free Flow listens.")
                .font(FFFont.text(15)).foregroundStyle(Palette.muted)
            if !mac.accessibility {
                Button("Turn on Accessibility") { MacHost.shared.askAccessibility() }.buttonStyle(FFButtonStyle(.primary))
            }
            if let note = FnKeySetting.note {
                Text(note).font(FFFont.text(14)).foregroundStyle(Palette.warn)
            }
        }
        .ffCard()
        .onAppear { MacHost.shared.refresh() }
    }
}
#endif
