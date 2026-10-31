import AppKit
import FluidAudio
import FreeFlowKit
import SwiftUI

/// Free Flow for Mac: a normal app with a Dock icon and its window (nearly the same experience as the iPhone and
/// iPad app), plus a menu-bar item that shows the state and the style. The window opens at launch and whenever the app
/// is opened again; closing it leaves fn dictation running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let dictation = MacDictation.shared
    private let models = MacModels.shared
    private let setup = SetupModel()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Free Flow downloads and sha256-checks every model file itself (MacModels); FluidAudio must never fetch on its own.
        ModelHub.offlineMode = true
        FFFont.register()
        let env = ProcessInfo.processInfo.environment
        #if DEBUG || FF_TESTS
        if let mode = SelfTest.mode() {
            Task { @MainActor in
                let code = await SelfTest.run(mode)
                exit(code)
            }
            return
        }
        #endif
        makeStatusItem()
        dictation.openSetup = { [weak self] in self?.showSetup() }
        // FF_MAC_SMOKE=1 (launch-and-quit checks on a Mac someone is using): no fn tap and no window, menu bar only.
        if env["FF_MAC_SMOKE"] == "1" {
            print("FFMAC smoke launched statusItem=\(statusItem != nil) speechReady=\(models.speechReady) ax=\(AXIsProcessTrusted())")
            fflush(stdout)
            return
        }
        dictation.startHotkey()
        NSApp.mainMenu = makeMainMenu()
        showSetup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Free Flow again (Dock, Finder, Launchpad, Spotlight) brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    /// The app menu, Edit (so copy and paste work in the dictionary field) and Window.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            top.submenu = menu
            main.addItem(top)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, target: AnyObject? = nil, mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        add("Free Flow", [
            item("About Free Flow", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(openSetup), ",", target: self),
            .separator(),
            item("Hide Free Flow", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Free Flow", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", mods: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    // MARK: Menu bar

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Free Flow")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if (note.object as? NSWindow) === self?.window { self?.setup.stop() }
            }
        })
        // The icon turns ember while the mic is on.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await phase in self.dictation.$phase.values {
                let on = phase == .listening || phase == .handsFree
                self.statusItem?.button?.contentTintColor = on ? NSColor(srgbRed: 1, green: 0x5A / 255, blue: 0x1F / 255, alpha: 1) : nil
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        switch dictation.phase {
        case .listening: state = "Listening. Let go of fn to type it."
        case .handsFree: state = "Listening hands-free. Press fn to stop."
        case .working: state = "Writing…"
        case .idle: state = setup.ready ? "Hold fn and talk" : "Finish setting up Free Flow"
        }
        let head = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let styles = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in DictationStyle.allCases {
            let i = NSMenuItem(title: s.pill, action: #selector(pickStyle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.rawValue
            i.state = dictation.style == s ? .on : .off
            sub.addItem(i)
        }
        styles.submenu = sub
        menu.addItem(styles)

        let paste = NSMenuItem(title: "Paste last dictation", action: #selector(pasteLast), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = !dictation.lastText.isEmpty
        menu.addItem(paste)
        let copy = NSMenuItem(title: "Copy last dictation", action: #selector(copyLast), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = !dictation.lastText.isEmpty
        menu.addItem(copy)
        if dictation.failedAudio != nil {
            let retry = NSMenuItem(title: "Try the last recording again", action: #selector(retry), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Settings…", action: #selector(openSetup), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Free Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = DictationStyle(rawValue: raw) { dictation.style = s }
    }
    @objc private func pasteLast() { dictation.pasteLast() }
    @objc private func copyLast() { dictation.copyLast() }
    @objc private func retry() { dictation.retryFailed() }
    @objc private func openSetup() { showSetup() }

    // MARK: Setup window

    func showSetup() {
        if window == nil {
            let view = SetupView(setup: setup, models: models, dictation: dictation, dictionary: dictation.dictionary)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Free Flow"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            window = w
        }
        setup.watch()
        models.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
