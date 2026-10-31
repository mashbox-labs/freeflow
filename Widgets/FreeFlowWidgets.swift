import ActivityKit
import AppIntents
import FreeFlowKit
import SwiftUI
import WidgetKit

@main
struct FreeFlowWidgets: WidgetBundle {
    var body: some Widget {
        DictateControl()
        SessionControl()
        DictationLiveActivity()
    }
}

/// Control Center, Lock Screen and Action Button: Start/Stop Free Flow. Typed at the cursor when the Free Flow
/// keyboard is up, otherwise copied. The kind string is unchanged so controls people already placed keep working.
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "freeflow.control.dictate") {
            ControlWidgetButton(action: ToggleDictationIntent()) { Label("Free Flow", systemImage: "mic.fill") }
        }
        .displayName("Start/Stop Free Flow")
        .description("Press to dictate, press again to stop. Typed at your cursor with the Free Flow keyboard up, otherwise copied.")
    }
}

/// Keep the mic session warm so the keyboard dictates without switching apps.
struct SessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "freeflow.control.session") {
            ControlWidgetButton(action: StartSessionIntent()) { Label("Free Flow session", systemImage: "waveform") }
        }
        .displayName("Free Flow session")
        .description("Keep the Free Flow keyboard ready to dictate.")
    }
}

struct DictationLiveActivity: Widget {
    private let brand = Color(red: 1, green: 0.353, blue: 0.122)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.phase == "Listening" ? "waveform" : "mic.fill").font(.title2).foregroundStyle(brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase == "Ready" ? "Free Flow ready" : "FREE FLOW · \(context.state.phase)").font(.headline)
                    if context.state.phase == "Ready", let end = context.state.endsAt, end > Date() {
                        HStack(spacing: 4) {
                            Text("Mic off in")
                            Text(timerInterval: Date()...end, countsDown: true).monospacedDigit()
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(context.state.detail.isEmpty ? context.attributes.modelName : context.state.detail)
                            .font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(intent: FinishDictationIntent()) { Label("Stop", systemImage: "stop.fill") }.tint(brand)
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.06, green: 0.05, blue: 0.04))
            .activitySystemActionForegroundColor(brand)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "waveform").foregroundStyle(brand) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.phase).font(.caption) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail.isEmpty ? context.attributes.modelName : context.state.detail).font(.subheadline).lineLimit(2)
                        Spacer()
                        Button(intent: FinishDictationIntent()) { Image(systemName: "stop.fill") }.tint(brand)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(brand)
            } compactTrailing: {
                Text(context.state.phase.prefix(1)).font(.caption2)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(brand)
            }
        }
    }
}

struct WidgetIntentsPackageList: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FreeFlowIntentsPackage.self] }
}
