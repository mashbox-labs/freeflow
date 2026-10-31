import FluidAudio
import FreeFlowKit
import SwiftUI
import UIKit

@main
struct FreeFlowApp: App {
    // Shared objects handed to the views, not observed here: with @StateObject every publish (build 8: every mic
    // buffer) re-ran this body and re-rendered the whole app, also in the background (cpu_resource_fatal, an iPad,
    // 10-29). Apple, StateObject: for an object the view creates and owns; the views observe what they show.
    private let engine = DictationEngine.shared
    private let models = ModelManager.shared
    private let dictionary = DictionaryStore.shared
    private let history = HistoryStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Free Flow downloads and sha256-checks every model file itself (ModelManager). FluidAudio must never fetch on
        // its own: offline, a Parakeet file missing here throws (ModelManager.plainLoadError) and a failed load is
        // reported, never answered by deleting the checked files and fetching unpinned ones (ModelHub.loadModels).
        ModelHub.offlineMode = true
        SetupState.launched = Date()
        FFFont.register()
        Appearance.apply()
        DictationEngine.installIntentHooks()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay { PrepareLoader() }     // build 23: the first Neural Engine prepare of the pick, full screen
                .environmentObject(engine)
                .environmentObject(models)
                .environmentObject(dictionary)
                .environmentObject(history)
                .onOpenURL { engine.handle($0) }
                #if targetEnvironment(macCatalyst)
                .onAppear { MacHost.shared.start() }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    #if targetEnvironment(macCatalyst)
                    if phase == .active { MacHost.shared.refresh() }
                    #endif
                    if phase == .active { engine.becameActive() }
                    if phase == .background { engine.leftApp() }
                }
        }
    }
}

enum Appearance {
    static func apply() {
        let large = UIFont(name: "BigShouldersDisplay-Black", size: 40) ?? .systemFont(ofSize: 34, weight: .black)
        let inline = FFFont.uiText(18, .semibold)
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)]
        nav.titleTextAttributes = [.font: inline]
    }
}

struct AppIntentsPackageList: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FreeFlowIntentsPackage.self] }
}

import AppIntents

struct FreeFlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDictationIntent(),
                    phrases: ["Start \(.applicationName)", "Stop \(.applicationName)", "Dictate with \(.applicationName)"],
                    shortTitle: "Start/Stop", systemImageName: "mic.fill")
        AppShortcut(intent: StartSessionIntent(),
                    phrases: ["Start a \(.applicationName) session"],
                    shortTitle: "Start session", systemImageName: "waveform")
    }
}
