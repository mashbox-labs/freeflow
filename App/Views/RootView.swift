import FreeFlowKit
import SwiftUI

struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("appearance") private var appearance = "dark"
    @State private var tab = RootView.firstTab
    /// Whether setup shows, seeded from the saved flag and set directly when setup ends, so the switch never
    /// depends on reading the saved value back.
    @State private var showSetup: Bool?
    @ObservedObject private var cleanupAsk = CleanupAsk.shared

    var body: some View {
        // Setup or the app, chosen at the root. A full-screen cover set at launch could be dropped (seen on
        // iPad with the sidebar tab bar): the app then opened without its setup.
        Group {
            if showSetup ?? !onboarded {
                OnboardingView { onboarded = true; showSetup = false }
            } else {
                tabs
            }
        }
        .onChange(of: onboarded) { _, done in showSetup = !done }   // Settings > Show setup again
        .preferredColorScheme(Look.scheme(appearance))
        .tint(Palette.brand)
        // Build 33: cleanup is slow on this device; one tap turns it off.
        .alert(CleanupSpeed.question, isPresented: Binding(get: { cleanupAsk.asking }, set: { if !$0 { cleanupAsk.asking = false } })) {
            Button("Turn off cleanup") { cleanupAsk.answer(turnOff: true) }
            Button("Keep it", role: .cancel) { cleanupAsk.answer(turnOff: false) }
        }
    }

    /// The Mac tests open on a given tab for screenshots (FF_MAC_TEST=1 FF_MAC_TAB=history); otherwise Dictate.
    static var firstTab: String {
        #if targetEnvironment(macCatalyst)
        let env = ProcessInfo.processInfo.environment
        if env["FF_MAC_TEST"] == "1", let tab = env["FF_MAC_TAB"] { return tab }
        #endif
        return "dictate"
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Dictate", systemImage: "mic.fill", value: "dictate") { NavigationStack { HomeView() } }
            Tab("Models", systemImage: "cpu", value: "models") { NavigationStack { ModelsView() } }
            Tab("Dictionary", systemImage: "character.book.closed", value: "dictionary") { NavigationStack { DictionaryView() } }
            Tab("History", systemImage: "clock.arrow.circlepath", value: "history") { NavigationStack { HistoryView() } }
            Tab("Settings", systemImage: "gearshape", value: "settings") { NavigationStack { SettingsView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        // A keyboard opened Free Flow to record: one full-screen card sends the person back (ReturnCardView).
        .overlay { ReturnCardHost() }
    }
}

/// Dark like the mashbox.gg homepage by default; Light or Match system in Settings.
enum Look {
    static func scheme(_ value: String) -> ColorScheme? { value == "light" ? .light : (value == "system" ? nil : .dark) }
}

/// Page background and width limit so iPad layouts stay readable.
struct Page<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.fg)
    }
}
