import XCTest

/// Drives the real UI. Transcription is real: FF_AUDIO_FILE feeds a recorded speech clip through the
/// same capture path as the microphone (the simulator's mic would record the room the Mac is in).
final class FreeFlowUITests: XCTestCase {
    var app: XCUIApplication!
    private static var relaunchedAfterInstall = false

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(onboarded: Bool, extra: [String] = [], relaunchAfterInstall: Bool = true) {
        app = XCUIApplication()
        // A fresh setup starts on its first page (the saved step is read as 0; steps the test walks are still saved).
        app.launchArguments = ["-onboarded", onboarded ? "YES" : "NO"] + (onboarded ? [] : ["-setup.step", "0"]) + extra
        let env = ProcessInfo.processInfo.environment
        if let file = env["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        if let speed = env["FF_AUDIO_FEED_SPEED"] { app.launchEnvironment["FF_AUDIO_FEED_SPEED"] = speed }
        app.launch()
        // The first launch in each xcodebuild run follows its reinstall of the app, and SpringBoard can start that
        // process with no launch arguments and no environment (seen twice on an iPhone Air simulator: the
        // runningboard job descriptions had ProgramArguments count 1 and no FF_AUDIO_FILE, so both C++ walks recorded
        // the silent simulator mic; all 16 later launches that day had both). Launch once more, after the install.
        if !Self.relaunchedAfterInstall {
            Self.relaunchedAfterInstall = true
            if relaunchAfterInstall {
                XCTContext.runActivity(named: "First launch after install; launching again so the arguments arrive") { _ in
                    app.terminate()
                    app.launch()
                }
            }
        }
        // Right after xcodebuild installs the app, iOS can start it on its own and the test then attaches to that
        // process, which never got the arguments above (run13 iPhone: the only launch had 1 argument, the app
        // opened on the saved state, test1 failed). If the screen is the one the arguments rule out, launch once
        // more. A frozen app shows neither and still fails the test's own checks.
        let ours = onboarded ? app.buttons["micButton"] : app.buttons["onboarding.next"]
        let other = onboarded ? app.buttons["onboarding.next"] : app.buttons["micButton"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !ours.exists && !other.exists { usleep(250_000) }
        if other.exists && !ours.exists {
            XCTContext.runActivity(named: "App opened without the test's launch arguments; launching again") { _ in
                app.terminate()
                app.launch()
            }
        }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tab(_ name: String) {
        let bar = app.tabBars.buttons[name]
        let button = bar.exists ? bar : app.buttons[name].firstMatch
        // Tap only once the tab is really on screen. A tap sent while SpringBoard is still animating Free Flow in lands
        // on the Home Screen (2026-10-29: the Models tap 0.2 s after activate() opened Safari).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !(button.exists && button.isHittable) { usleep(250_000) }
        button.tap()
        sleep(1)
    }

    /// Brings Free Flow to the front and waits until it is really there before any tap (after every
    /// activate()). XCTest can call the app foreground while SpringBoard is still animating it in.
    private func bringForward() {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Free Flow did not come to the front")
        let bar = app.tabBars.buttons["Models"]
        let models = bar.exists ? bar : app.buttons["Models"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !(models.exists && models.isHittable) { usleep(250_000) }
        XCTAssertTrue(models.exists && models.isHittable, "Free Flow's tab bar is not on screen after coming to the front")
        sleep(1)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func scrollTo(_ e: XCUIElement, max: Int = 8) {
        var n = 0
        while !e.isHittable && n < max { app.swipeUp(); n += 1 }
    }

    /// Finish, after scrolling back up to it: in build 18 the test opens the "Written by" details lower on Home, so the
    /// page can sit scrolled down with the dictate card under the top bar (gate air-b18w 10-30: the tap landed there).
    /// Taps Finish and checks it took: the key turns disabled (processing) or goes away. A scrolled page can leave the
    /// key under the title bar, where XCUITest calls it hittable but the tap lands on the bar, so scroll up and retry.
    private func tapFinish() {
        let finish = app.buttons["finishButton"]
        for attempt in 0..<4 {
            var n = 0
            while (n < attempt * 2 || !finish.isHittable) && n < 8 { app.swipeDown(); n += 1 }
            finish.tap()
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                if !finish.exists || !finish.isEnabled { return }
                usleep(250_000)
            }
            print("FFFINISH tap \(attempt + 1) did not take, scrolling up")
        }
    }

    // MARK: Start/Stop Free Flow through the real Control Center
    // The simulator has no Action Button choice (Settings > Action Button offers only No Action), no Siri and no
    // Back Tap, so these drive the same control from Control Center. Lock Screen and Action Button run that control.

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// The Start/Stop control placed in Control Center (its button carries the control kind as identifier).
    private func freeFlowControl(_ sb: XCUIApplication, kind: String = "freeflow.control.dictate") -> XCUIElement {
        sb.buttons[kind].firstMatch
    }

    /// The gallery tile for the control. Only the tile (an Icon) adds it; the button inside it does not.
    private func galleryTile(_ sb: XCUIApplication, name: String = "Start/Stop Free Flow") -> XCUIElement {
        sb.icons[name].firstMatch
    }

    private func galleryIsOpen(_ sb: XCUIApplication) -> Bool { sb.searchFields["Search Controls"].exists }

    /// Swipes down from the top-right corner until Control Center is open.
    private func swipeIntoControlCenter(_ sb: XCUIApplication) {
        for attempt in 0..<4 {
            let dy = [0.0, 0.004, 0.01, 0.002][attempt]
            sb.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: dy))
                .press(forDuration: 0.15, thenDragTo: sb.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.75)))
            if sb.buttons["Add Controls"].waitForExistence(timeout: 3) { return }
        }
        XCTFail("Control Center did not open")
    }

    /// Opens Control Center and returns the Free Flow control, adding it the way a person does the first time.
    private func openControlCenter(kind: String = "freeflow.control.dictate", tile: String = "Start/Stop Free Flow") -> XCUIElement {
        let sb = springboard
        swipeIntoControlCenter(sb)
        let control = freeFlowControl(sb, kind: kind)
        if control.waitForExistence(timeout: 2) && !galleryIsOpen(sb) { return control }
        sb.buttons["Add Controls"].tap(); sleep(2)
        sb.buttons["Add a Control"].tap(); sleep(2)
        let search = sb.searchFields["Search Controls"]
        let clear = sb.buttons["Clear text"]
        if clear.exists { clear.tap(); sleep(1) }
        search.tap(); search.typeText("Free Flow"); sleep(3)
        shot("t0-gallery-search")
        var pick = galleryTile(sb, name: tile)
        if !pick.waitForExistence(timeout: 5) {
            // Not found by search: clear it and page through the whole gallery, printing what is there.
            if sb.buttons["Clear text"].exists { sb.buttons["Clear text"].tap(); sleep(1) }
            if sb.buttons["Cancel"].exists { sb.buttons["Cancel"].tap(); sleep(1) }
            var seen = Set<String>()
            for i in 0..<30 {
                let labels = sb.staticTexts.allElementsBoundByIndex.map { $0.label }.filter { !seen.contains($0) }
                labels.forEach { seen.insert($0) }
                print("FFTRIGGER gallery page \(i): " + labels.joined(separator: " | "))
                pick = galleryTile(sb, name: tile)
                if pick.exists { break }
                sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
                sleep(1)
            }
            shot("t0-gallery-scrolled")
        }
        XCTAssertTrue(pick.exists, "Start/Stop Free Flow is not in the Control Center gallery")
        pick.tap()
        // Adding the control closes the gallery and leaves Control Center in edit mode.
        let added = sb.searchFields["Search Controls"].waitForNonExistence(timeout: 20)
        shot("t0-control-added")
        XCTAssertTrue(added, "tapping Start/Stop Free Flow in the gallery did not add it")
        // Leave edit mode and Control Center, then open it again the way a person does.
        XCUIDevice.shared.press(.home); sleep(2)
        swipeIntoControlCenter(sb)
        XCTAssertTrue(control.waitForExistence(timeout: 5) && !galleryIsOpen(sb), "the Free Flow control is not in Control Center after adding it")
        return control
    }

    private func closeControlCenter() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        sleep(1)
    }

    private func pressControl(_ name: String) {
        let control = openControlCenter()
        // A control that just came into view has no content or action until its extension renders it
        // (chronod: "creating the content on demand"); a tap before that does nothing. People never tap that fast.
        sleep(3)
        control.tap()
        sleep(1)
        shot(name)
        closeControlCenter()
    }

    /// A fresh simulator with two keyboards shows iOS's "Quickly Change Keyboards" tip over the keyboard the first time a
    /// field gets focus; until its Continue button is tapped the globe key does nothing (iPhone mini and SE simulators).
    private func dismissKeyboardTip(in target: XCUIApplication) {
        guard target.staticTexts["Quickly Change Keyboards"].waitForExistence(timeout: 1) else { return }
        let go = target.buttons["Continue"]
        if go.exists { go.tap(); sleep(1); print("FFSETUP keyboard tip: dismissed") }
    }

    /// From whatever keyboard shows, switch to Free Flow's the way a person does. On iPhone a tap on the globe goes to the
    /// next keyboard. On iPad the globe key (identifier "emoji", label "Next keyboard") goes to Emoji, and the Emoji
    /// keyboard has no globe, only ABC back (iPad Pro 13 run 10-30 18:0xZ), so a person holds the globe and picks
    /// Free Flow from the list.
    private func switchToFreeFlow(in host: XCUIApplication, key: XCUIElement) -> Bool {
        for attempt in 0..<4 {
            if key.exists { return true }
            dismissKeyboardTip(in: host)
            let abc = host.buttons["ABC"].firstMatch
            if abc.exists && abc.isHittable { abc.tap(); sleep(1) }   // out of Emoji, back to the letters
            let globe = host.buttons.matching(NSPredicate(format: "label == 'Next keyboard'")).firstMatch
            guard globe.waitForExistence(timeout: 3) else { break }
            let iPad = globe.identifier == "emoji"
            if !iPad && attempt < 3 {
                globe.tap()
            } else {
                let match = NSPredicate(format: "label == 'Free Flow' OR label BEGINSWITH 'Free Flow,'")
                let before = Set(host.descendants(matching: .any).matching(match).allElementsBoundByIndex.map { NSCoder.string(for: $0.frame) })
                globe.press(forDuration: 1.2)
                sleep(1)
                let shown = host.descendants(matching: .any).matching(match).allElementsBoundByIndex
                    .filter { !before.contains(NSCoder.string(for: $0.frame)) && $0.isHittable }
                print("FFSETUP keyboard list: \(shown.count) new 'Free Flow' item(s)")
                if let item = shown.last { item.tap() } else { print("FFSETUP no list: " + host.debugDescription.suffix(4000)) }
            }
            if key.waitForExistence(timeout: 5) { return true }
            dismissKeyboardTip(in: host)   // the tip can appear after the first globe tap and swallow the next ones
            if key.waitForExistence(timeout: 2) { return true }
        }
        return key.exists
    }

    /// Brings up the Free Flow keyboard the way a person does: tap the field, then the globe key if another keyboard shows.
    private func showFreeFlowKeyboard(tapping field: XCUIElement) -> Bool {
        field.tap()
        let mic = app.buttons["kb.mic"]
        if mic.waitForExistence(timeout: 8) { return true }
        dismissKeyboardTip(in: app)
        let globe = app.buttons["Next keyboard"]
        for _ in 0..<3 where globe.exists && !mic.exists {
            globe.tap()
            if mic.waitForExistence(timeout: 5) { return true }
            dismissKeyboardTip(in: app)   // the tip can appear after the first globe tap and swallow the next ones
            if mic.waitForExistence(timeout: 2) { return true }
        }
        return mic.exists
    }

    /// The Free Flow keyboard inside ANOTHER app: tap the field, then the globe key until Free Flow's keyboard shows.
    private func showFreeFlowKeyboard(in host: XCUIApplication, tapping field: XCUIElement) -> Bool {
        field.tap()
        let mic = host.buttons["kb.mic"]
        if mic.waitForExistence(timeout: 8) { return true }
        return switchToFreeFlow(in: host, key: mic)
    }

    private func startWarmSession() {
        let session = app.buttons["sessionButton"]
        scrollTo(session)
        if session.label == "Start session" { session.tap(); sleep(2) }
    }

    /// Keyboard up: the control starts the dictation, the keyboard follows it, and the text is typed at the cursor.
    func test6aTriggerTyped() {
        launch(onboarded: true)
        startWarmSession()
        let field = element("tryField")
        scrollTo(field)
        XCTAssertTrue(showFreeFlowKeyboard(tapping: field), "Free Flow keyboard did not appear")
        pressControl("t1-control-start")
        XCTAssertTrue(app.buttons["kb.finishButton"].waitForExistence(timeout: 10), "the keyboard did not show the control's dictation")
        shot("t2-keyboard-listening")
        sleep(12)
        pressControl("t3-control-stop")
        let deadline = Date().addingTimeInterval(180)
        var value = ""
        while Date() < deadline {
            value = (field.value as? String) ?? ""
            if value.lowercased().contains("country") { break }
            sleep(1)
        }
        print("FFTRIGGER typed: " + value)
        shot("t4-typed")
        XCTAssertTrue(value.lowercased().contains("country"), value)
    }

    /// App in the background, warm session, no keyboard: no app switch, the text is copied and a small notice says so.
    func test6bTriggerCopied() {
        launch(onboarded: true)
        startWarmSession()
        tab("Settings")
        let link = app.buttons["Action Button and Control Center"]
        scrollTo(link)
        link.tap()
        let notice = element("noticeButton")
        scrollTo(notice)
        notice.tap()
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(2)
        pressControl("t5-control-start")
        XCTAssertNotEqual(app.state, .runningForeground, "a warm press must not open the app")
        sleep(12)
        pressControl("t6-control-stop")
        XCTAssertNotEqual(app.state, .runningForeground, "a warm press must not open the app")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'on the clipboard'")).firstMatch
        let seen = banner.waitForExistence(timeout: 120)
        shot("t7-copied-notice")
        print("FFTRIGGER notice: " + (seen ? banner.label : "none"))
        XCTAssertTrue(seen, "no Copied notice")
    }

    /// C++ model, app in the background (as test6b): the dictation must run on the CPU, never Metal. Then the app is
    /// brought forward without a relaunch and Models > Live stats must read "C++ (ggml) · CPU". Env FF_TEST_MODEL.
    func test6eBackgroundCppRunsOnCPU() {
        let model = ProcessInfo.processInfo.environment["FF_TEST_MODEL"] ?? "parakeet-gguf-q4_0"
        launch(onboarded: true, extra: ["-activeModel", model])
        startWarmSession()
        XCUIDevice.shared.press(.home)
        sleep(2)
        pressControl("e1-control-start")
        XCTAssertNotEqual(app.state, .runningForeground, "a warm press must not open the app")
        sleep(12)
        pressControl("e2-control-stop")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'on the clipboard'")).firstMatch
        let seen = banner.waitForExistence(timeout: 180)
        print("FFBG notice: " + (seen ? banner.label : "none"))
        bringForward()
        tab("Models")
        // The Engine row's value, as ModelsView writes it: "C++ (ggml) · " + CPU / GPU (Metal) / not run yet. Model cards
        // also start with "C++ (ggml) · " (quantization and size), so match the whole value, not the prefix.
        let engine = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"C\+\+ \(ggml\) · (CPU|GPU \(Metal\)|not run yet)"#)).firstMatch
        XCTAssertTrue(engine.waitForExistence(timeout: 30), "no Engine row: the active model is not a C++ model")
        shot("e3-live-stats")
        print("FFENGINE " + model + ": " + engine.label)
        XCTAssertTrue(engine.label.hasSuffix("CPU"), engine.label)
    }

    /// C++ model, warm session, Free Flow in the background and its keyboard in ANOTHER app (Contacts): how the keyboard
    /// dictates without switching apps, so the C++ engine loads and transcribes with Free Flow in the background. The
    /// text must land in Contacts with Free Flow never in front; then Free Flow is brought forward and Models > Live
    /// stats must read "C++ (ggml) · CPU" (the backend the last real run used; "not run yet" fails). The simulator
    /// always runs the C++ engine on the CPU (Transcriber.backendNow); on a device the background picks the CPU.
    /// Replaces test6e in the gate (2026-10-29): a Control Center press runs no Free Flow intent in the iOS 26.5
    /// simulator (chronod aborts in LinkServices LNAppIntentConnectionPolicy on every press). Env FF_TEST_MODEL.
    func test6fBackgroundCppKeyboard() {
        let model = ProcessInfo.processInfo.environment["FF_TEST_MODEL"] ?? "parakeet-gguf-q4_0"
        launch(onboarded: true, extra: ["-activeModel", model])
        startWarmSession()
        XCTAssertNotEqual(app.buttons["sessionButton"].label, "Start session", "the warm session did not start")
        XCUIDevice.shared.press(.home)
        sleep(2)
        let host = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
        host.launch()
        let search = host.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Contacts has no search field")
        XCTAssertTrue(showFreeFlowKeyboard(in: host, tapping: search), "Free Flow keyboard did not appear in Contacts")
        shot("f1-host-keyboard")
        host.buttons["kb.mic"].tap()
        let finish = host.buttons["kb.finishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 15), "the keyboard did not start listening")
        XCTAssertNotEqual(app.state, .runningForeground, "a warm session must not open Free Flow")
        sleep(4); shot("f2-host-listening")
        sleep(8) // the clip is 11 s
        finish.tap()
        let deadline = Date().addingTimeInterval(180)
        var value = ""
        while Date() < deadline {
            value = (search.value as? String) ?? ""
            if value.lowercased().contains("country") { break }
            sleep(1)
        }
        print("FFBGKEYBOARD " + model + ": " + value)
        shot("f3-host-inserted")
        XCTAssertNotEqual(app.state, .runningForeground, "Free Flow came to the front during the dictation")
        XCTAssertTrue(value.lowercased().contains("country"), value)
        bringForward()
        tab("Models")
        // The Engine row's value, as ModelsView writes it: "C++ (ggml) · " + CPU / GPU (Metal) / not run yet. Model cards
        // also start with "C++ (ggml) · " (quantization and size), so match the whole value, not the prefix.
        let engine = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"C\+\+ \(ggml\) · (CPU|GPU \(Metal\)|not run yet)"#)).firstMatch
        XCTAssertTrue(engine.waitForExistence(timeout: 30), "no Engine row: the active model is not a C++ model")
        shot("f4-live-stats")
        print("FFENGINE " + model + ": " + engine.label)
        XCTAssertTrue(engine.label.hasSuffix("CPU"), engine.label)
    }

    /// App not running: iOS will not start the mic in the background, so the press opens Free Flow and it listens there.
    func test6cTriggerCold() {
        launch(onboarded: true)
        app.terminate()
        XCUIDevice.shared.press(.home)
        sleep(2)
        pressControl("t8-control-cold-start")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "the cold press did not bring Free Flow forward")
        XCTAssertTrue(element("finishButton").waitForExistence(timeout: 15), "Free Flow did not start listening after the cold press")
        shot("t9-cold-listening")
        sleep(12)
        pressControl("t10-control-stop")
        let text = element("transcriptText")
        XCTAssertTrue(text.waitForExistence(timeout: 180))
        print("FFTRIGGER cold: " + text.label)
        shot("t11-cold-done")
        XCTAssertTrue(text.label.lowercased().contains("country"), text.label)
    }

    /// Build 31: ONE action. The Control Center gallery offers Start/Stop Free Flow and no session control.
    func test6dOneControlOnly() {
        launch(onboarded: true)
        XCUIDevice.shared.press(.home)
        sleep(2)
        _ = openControlCenter()   // adds Start/Stop if missing, the way a person does
        let sb = springboard
        sb.buttons["Add Controls"].tap(); sleep(2)
        sb.buttons["Add a Control"].tap(); sleep(2)
        let search = sb.searchFields["Search Controls"]
        search.tap(); search.typeText("Free Flow"); sleep(3)
        let tiles = sb.icons.matching(NSPredicate(format: "label CONTAINS 'Free Flow'")).allElementsBoundByIndex.map(\.label)
        shot("t12-gallery-free-flow")
        print("FFINTENT control gallery: " + tiles.joined(separator: " | "))
        XCUIDevice.shared.press(.home); sleep(1)
        XCUIDevice.shared.press(.home); sleep(1)
        XCTAssertFalse(tiles.contains("Free Flow session"), "the session control is still offered")
        XCTAssertTrue(tiles.contains("Start/Stop Free Flow"), "Start/Stop Free Flow is not offered")
    }

    // MARK: Shortcuts and the Live Activity rule (build 31: a build 30 crash, iOS 27.2)
    // iOS ends the app (AppIntents PerformActionExecutorTask.verifySystemPolicy) when an AudioRecordingIntent returns
    // with the mic on and no Live Activity. These press the real control with Live Activities off, warm and cold, then
    // once more after, and check that Free Flow is still running.

    private var settingsApp: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Preferences") }

    /// Settings > Apps > Free Flow > Live Activities, the way a person turns it off or on.
    private func setLiveActivities(_ on: Bool) {
        let prefs = settingsApp
        prefs.terminate()
        prefs.launch()
        let toggle = prefs.switches.matching(NSPredicate(format: "label CONTAINS[c] 'Live Activities'")).firstMatch
        var found = false
        let apps = prefs.staticTexts["Apps"].firstMatch
        for _ in 0..<6 where !apps.isHittable { prefs.swipeUp() }
        if apps.exists {
            apps.tap(); sleep(2)
            let ff = prefs.staticTexts["Free Flow"].firstMatch
            for _ in 0..<12 where !(ff.exists && ff.isHittable) { prefs.swipeUp() }
            if ff.exists { ff.tap(); sleep(2); found = toggle.waitForExistence(timeout: 5) }
        }
        if !found {
            print("FFINTENT settings tree: " + String(prefs.debugDescription.suffix(5000)))
            XCTFail("Settings > Apps > Free Flow > Live Activities not found"); return
        }
        for _ in 0..<12 where !toggle.isHittable { prefs.swipeUp() }
        let isOn = (toggle.value as? String) == "1"
        if isOn != on { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap(); sleep(1) }
        let now = (toggle.value as? String) == "1"
        print("FFINTENT live activities \(isOn ? "on" : "off") -> \(now ? "on" : "off")")
        XCTAssertEqual(now, on, "could not turn Live Activities \(on ? "on" : "off")")
        XCUIDevice.shared.press(.home); sleep(1)
    }

    private func stateName(_ s: XCUIApplication.State) -> String {
        switch s {
        case .notRunning: return "notRunning"
        case .runningBackground, .runningBackgroundSuspended: return "background"
        case .runningForeground: return "foreground"
        default: return "unknown"
        }
    }

    /// Warm session (as the keyboard leaves it), then Live Activities off, then the control. Build 30 dies here.
    func test7aLiveActivitiesOffWarm() {
        launch(onboarded: true)
        addTeardownBlock { [unowned self] in self.setLiveActivities(true) }
        startWarmSession()
        XCTAssertNotEqual(app.buttons["sessionButton"].label, "Start session", "the warm session did not start")
        XCUIDevice.shared.press(.home); sleep(2)
        setLiveActivities(false)
        pressControl("p1-off-warm-press")
        sleep(4)
        let first = stateName(app.state)
        print("FFINTENT 7a warm press with Live Activities off: app=" + first)
        pressControl("p2-off-warm-press-again")
        sleep(4)
        let second = stateName(app.state)
        print("FFINTENT 7a second press: app=" + second)
        XCTAssertNotEqual(first, "notRunning", "Free Flow ended on the press (the build 30 crash)")
        XCTAssertNotEqual(second, "notRunning", "Free Flow ended on the second press")
        bringForward()
        let session = app.buttons["sessionButton"]
        scrollTo(session)
        print("FFINTENT 7a session after: " + session.label)
        XCTAssertFalse(element("finishButton").exists, "Free Flow is listening with no Live Activity")
    }

    /// Free Flow not running, Live Activities off, then the control (it opens Free Flow). Build 30 dies here.
    func test7bLiveActivitiesOffCold() {
        launch(onboarded: true)
        addTeardownBlock { [unowned self] in self.setLiveActivities(true) }
        app.terminate()
        setLiveActivities(false)
        pressControl("p3-off-cold-press")
        _ = app.wait(for: .runningForeground, timeout: 15)
        sleep(5)
        let state = stateName(app.state)
        print("FFINTENT 7b cold press with Live Activities off: app=" + state)
        shot("p4-off-cold-after")
        XCTAssertNotEqual(state, "notRunning", "Free Flow ended on the cold press (the build 30 crash)")
        XCTAssertFalse(element("finishButton").exists, "Free Flow is listening with no Live Activity")
    }

    /// Live Activities back on after 7a/7b: warm press starts and stops as in build 25, from the background, copied.
    func test7cOnAgainWarmStartStop() {
        setLiveActivities(true)
        launch(onboarded: true)
        startWarmSession()
        XCUIDevice.shared.press(.home); sleep(2)
        pressControl("p5-on-warm-start")
        XCTAssertNotEqual(app.state, .notRunning, "Free Flow ended on the start press")
        XCTAssertNotEqual(app.state, .runningForeground, "a warm press must not open the app")
        sleep(12)
        pressControl("p6-on-warm-stop")
        XCTAssertNotEqual(app.state, .notRunning, "Free Flow ended on the stop press")
        bringForward()
        let text = element("transcriptText")
        XCTAssertTrue(text.waitForExistence(timeout: 180))
        print("FFINTENT 7c warm text: " + text.label)
        XCTAssertTrue(text.label.lowercased().contains("country"), text.label)
    }

    /// The Live Activity's Stop button (FinishDictationIntent) on the Lock Screen finishes the dictation.
    func test7dLiveActivityStop() {
        setLiveActivities(true)
        launch(onboarded: true)
        startWarmSession()
        XCUIDevice.shared.press(.home); sleep(2)
        pressControl("p7-start-for-stop")
        sleep(8)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)   // wakes to the Lock Screen
        sleep(2)
        let stop = springboard.buttons["Stop"].firstMatch
        let seen = stop.waitForExistence(timeout: 10)
        shot("p8-lock-screen")
        print("FFINTENT 7d Stop on Lock Screen: " + (seen ? "shown" : "not shown"))
        if !seen { print("FFINTENT lock tree: " + String(springboard.debugDescription.suffix(4000))) }
        XCTAssertTrue(seen, "no Stop button on the Lock Screen Live Activity")
        stop.tap()
        sleep(4)
        XCTAssertNotEqual(app.state, .notRunning, "Free Flow ended on Stop")
        // Security (build 32): the locked screen shows the status, never the dictated words.
        sleep(8)
        let words = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'country'")).count
        shot("p8b-lock-screen-after-stop")
        print("FFINTENT 7d lock screen words after stop: \(words)")
        XCTAssertEqual(words, 0, "the Lock Screen shows the dictated words")
        XCUIDevice.shared.press(.home); sleep(1)
        springboard.swipeUp(); sleep(2)   // unlock (no passcode on the simulator)
        bringForward()
        let text = element("transcriptText")
        XCTAssertTrue(text.waitForExistence(timeout: 180), "Stop did not finish the dictation")
        print("FFINTENT 7d text: " + text.label)
    }

    /// Build 32: Start/Stop Free Flow runs only from its Control. In the Shortcuts app's action search,
    /// "Free Flow" finds no Free Flow action, while the same search for "Notes" does find Notes' actions (the search works).
    func test7eShortcutsAppHasNoFreeFlowAction() {
        launch(onboarded: true)
        app.terminate()
        let sc = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        sc.terminate(); sc.launch(); sleep(3)
        for b in ["Continue", "Not Now", "OK"] where sc.buttons[b].exists { sc.buttons[b].tap(); sleep(1) }
        let add = sc.buttons.matching(NSPredicate(format: "label == 'Add' OR label == 'New Shortcut' OR label == 'Create Shortcut' OR identifier == 'Add'")).firstMatch
        guard add.waitForExistence(timeout: 10) else {
            print("FFINTENT shortcuts tree: " + String(sc.debugDescription.suffix(6000))); XCTFail("no + in the Shortcuts app"); return
        }
        add.tap(); sleep(3)
        let search = sc.searchFields.firstMatch
        guard search.waitForExistence(timeout: 10) else {
            print("FFINTENT editor tree: " + String(sc.debugDescription.suffix(6000))); XCTFail("no action search field"); return
        }
        func results(_ q: String) -> [String] {
            search.tap()
            if let v = search.value as? String, !v.isEmpty, v != search.placeholderValue { search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count)) }
            search.typeText(q); sleep(4)
            return (sc.staticTexts.allElementsBoundByIndex + sc.buttons.allElementsBoundByIndex).map(\.label).filter { !$0.isEmpty }
        }
        let notes = results("Notes")
        let ff = results("Free Flow")
        shot("p9-shortcuts-search")
        print("FFINTENT shortcuts search Notes: " + notes.prefix(15).joined(separator: " | "))
        print("FFINTENT shortcuts search Free Flow: " + ff.prefix(25).joined(separator: " | "))
        XCTAssertTrue(notes.contains { $0.localizedCaseInsensitiveContains("note") && $0 != "Notes" }, "the action search found nothing for Notes, so it proves nothing")
        XCTAssertFalse(ff.contains { $0.contains("Start/Stop") || $0.contains("Stop Free Flow") || $0.contains("Free Flow session") }, "a Free Flow action is listed")
        sc.terminate()
    }

    // MARK: Keyboardless shortcut probes (measure only, nothing asserted about the outcome)

    private func focusState(_ host: XCUIApplication, _ field: XCUIElement) -> String {
        let focus = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        return "focus=\(focus) ffKeyboard=\(host.buttons["kb.mic"].exists || host.buttons["kb.finishButton"].exists) anyKeyboard=\(host.keyboards.count > 0 || host.buttons["kb.hide"].exists) value='\((field.value as? String) ?? "")'"
    }

    private func contactsSearch() -> (XCUIApplication, XCUIElement) {
        let host = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
        host.terminate(); host.launch()
        let search = host.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Contacts has no search field")
        return (host, search)
    }

    /// Q1+Q2: keyboard dictation, then the Hide key mid-dictation; finished by the control; then the field again.
    func test8aHideMidDictation() {
        launch(onboarded: true)
        startWarmSession()
        XCUIDevice.shared.press(.home); sleep(2)
        let (host, search) = contactsSearch()
        XCTAssertTrue(showFreeFlowKeyboard(in: host, tapping: search), "Free Flow keyboard did not appear")
        host.buttons["kb.mic"].tap()
        XCTAssertTrue(host.buttons["kb.finishButton"].waitForExistence(timeout: 15), "the keyboard did not start listening")
        sleep(3)
        host.buttons["kb.hide"].firstMatch.tap(); sleep(2)
        print("FFPROBE 8a after Hide while listening: " + focusState(host, search))
        shot("k1-hidden-listening")
        sleep(8)
        pressControl("k2-control-stop")
        host.activate(); sleep(6)
        print("FFPROBE 8a after stop, keyboard still hidden: " + focusState(host, search))
        search.tap(); sleep(5)
        print("FFPROBE 8a after tapping the field again: " + focusState(host, search))
        shot("k3-field-again")
        print("FFPROBE 8a clipboard has text: \(UIPasteboard.general.hasStrings)")
    }

    /// Q2+Q3: the control starts with no keyboard on screen (Contacts open, no field focused); stop; then the field.
    func test8bShortcutNoKeyboardThenField() {
        launch(onboarded: true)
        startWarmSession()
        XCUIDevice.shared.press(.home); sleep(2)
        let (host, search) = contactsSearch()
        print("FFPROBE 8b before: " + focusState(host, search))
        pressControl("k4-control-start-no-keyboard")
        sleep(12)
        pressControl("k5-control-stop-no-keyboard")
        host.activate(); sleep(4)
        _ = showFreeFlowKeyboard(in: host, tapping: search)
        sleep(5)
        print("FFPROBE 8b after showing the Free Flow keyboard: " + focusState(host, search))
        shot("k6-field-after")
    }

    /// Q1+Q3: field focused with the Free Flow keyboard up, the control starts, Hide, then the control stops.
    func test8cShortcutKeyboardHiddenFieldFocused() {
        launch(onboarded: true)
        startWarmSession()
        XCUIDevice.shared.press(.home); sleep(2)
        let (host, search) = contactsSearch()
        XCTAssertTrue(showFreeFlowKeyboard(in: host, tapping: search), "Free Flow keyboard did not appear")
        pressControl("k7-control-start-keyboard-up")
        host.activate(); sleep(2)
        print("FFPROBE 8c listening with keyboard up: " + focusState(host, search))
        if host.buttons["kb.hide"].exists { host.buttons["kb.hide"].firstMatch.tap(); sleep(2) }
        print("FFPROBE 8c after Hide: " + focusState(host, search))
        sleep(8)
        pressControl("k8-control-stop-hidden")
        host.activate(); sleep(6)
        print("FFPROBE 8c after stop, hidden: " + focusState(host, search))
        search.tap(); sleep(5)
        print("FFPROBE 8c after tapping the field again: " + focusState(host, search))
        shot("k9-after")
    }

    /// Build 32 help text: iOS 27's own words on Settings > Action Button (measure only).
    func test9zActionButtonWording() {
        let prefs = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        prefs.terminate(); prefs.launch(); sleep(2)
        let row = prefs.staticTexts["Action Button"].firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { prefs.swipeUp() }
        print("FFWORDS settings row Action Button exists=\(row.exists)")
        guard row.exists else { print("FFWORDS root: " + prefs.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")); return }
        row.tap(); sleep(3)
        for page in 0..<14 {
            let words = prefs.staticTexts.allElementsBoundByIndex.map(\.label) + prefs.buttons.allElementsBoundByIndex.map(\.label)
            print("FFWORDS page \(page): " + words.filter { !$0.isEmpty }.joined(separator: " | "))
            let pick = prefs.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Choose a Control'")).firstMatch
            if pick.exists {
                pick.tap(); sleep(3)
                print("FFWORDS chooser: " + (prefs.staticTexts.allElementsBoundByIndex.map(\.label) + prefs.searchFields.allElementsBoundByIndex.map { $0.placeholderValue ?? "" }).joined(separator: " | "))
                break
            }
            prefs.swipeLeft(); sleep(2)
        }
    }

    /// Build 33: cleanup slow on 3 dictations in a row (seeded through the argument domain) asks once in the
    /// app; "Turn off cleanup" flips Settings > Writing; the question does not come back within 12 hours.
    func testCS1SlowCleanupAsksOnce() {
        launch(onboarded: true)
        tab("Settings")
        let toggle = app.switches["settings.appleWriter"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setSwitch(toggle, on: true)
        XCTAssertEqual(toggle.value as? String, "1", "cleanup must be on for this test")
        app.terminate()
        launch(onboarded: true, extra: ["-cleanup.slowStreak", "3", "-cleanup.askedAt", "<date>2000-01-01T00:00:00Z</date>"])
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no slow-cleanup question")
        print("FFCLEANUP alert: " + alert.label)
        shot("cs1-ask")
        XCTAssertTrue(alert.label.contains("Cleanup is taking a few seconds on this device"), alert.label)
        alert.buttons["Turn off cleanup"].tap()
        sleep(1)
        tab("Settings")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        print("FFCLEANUP toggle after: \(toggle.value as? String ?? "?")")
        XCTAssertEqual(toggle.value as? String, "0", "Turn off cleanup did not turn the setting off")
        setSwitch(toggle, on: true)   // back on, as before the test
        app.terminate()
        launch(onboarded: true, extra: ["-cleanup.slowStreak", "3"])
        sleep(4)
        print("FFCLEANUP asked again within 12 h: \(app.alerts.firstMatch.exists)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "asked again within 12 hours")
    }

    /// Gate setup on a freshly erased simulator, the steps a person takes the first time (2026-10-29: fix the
    /// gate, not the app): finish the in-app setup, then Settings > General > Keyboard > Keyboards > Add New Keyboard... >
    /// Free Flow, then Free Flow > Allow Full Access > Allow. Steps already done are left as they are. An erased
    /// simulator lists only English (US) and Emoji, so without this every keyboard test gets the iOS keyboard.
    func test0FreshSimulatorSetup() {
        launch(onboarded: false)
        if app.buttons["onboarding.next"].waitForExistence(timeout: 15) {
            var step = 1
            while app.buttons["onboarding.next"].exists && step < 12 {
                // The microphone page: tap Allow the microphone, then Allow on the iOS alert. Without this an erased
                // simulator asks at the first dictation and any run without the test clip waits behind that alert.
                let mic = app.buttons["allowMic"]
                if mic.exists && mic.isHittable {
                    mic.tap()
                    let allow = springboard.alerts.buttons["Allow"].firstMatch
                    if allow.waitForExistence(timeout: 5) { allow.tap() }
                    sleep(1)
                    print("FFSETUP microphone: " + (mic.exists ? "still asking" : "allowed"))
                }
                passModelPage(shots: true)
                app.buttons["onboarding.next"].tap(); sleep(1); step += 1
            }
            app.buttons["onboarding.done"].tap()
        }
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 10), "in-app setup did not end on the Dictate screen")
        app.terminate()
        XCTAssertTrue(addFreeFlowKeyboard(), "could not add the Free Flow keyboard in Settings")
        XCTAssertTrue(allowFullAccess(), "could not turn on Allow Full Access for the Free Flow keyboard")
    }

    /// Build 19: on the model page Next stays off until a speech model is downloaded and verified. When this
    /// device has none yet, check that, download the first model setup offers, watch the progress, and wait for Next.
    /// Returns false only when the page held Next off and the download never finished.
    @discardableResult
    private func passModelPage(shots: Bool) -> Bool {
        let next = app.buttons["onboarding.next"]
        guard element("onboarding.needsModel").exists else { return true }
        XCTAssertFalse(next.isEnabled, "Next is on with no speech model")
        if shots { shot("01-onboarding-model-next-off") }
        let download = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download.'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10), "setup offers no model to download")
        let id = String(download.identifier.dropFirst("download.".count))
        scrollTo(download)
        download.tap()
        XCTAssertTrue(element("progress.\(id)").waitForExistence(timeout: 30), "no download progress shown")
        if shots { sleep(2); shot("01-onboarding-model-downloading") }
        print("FFMODELGATE downloading \(id), Next enabled=\(next.isEnabled)")
        XCTAssertFalse(next.isEnabled, "Next came on while the model was still downloading")
        let on = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)
        let ok = XCTWaiter().wait(for: [on], timeout: 1500) == .completed
        print("FFMODELGATE \(id) verified, Next enabled=\(next.isEnabled)")
        return ok
    }

    func test1Onboarding() {
        launch(onboarded: false)
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 15))
        var step = 1
        while app.buttons["onboarding.next"].exists && step < 12 {
            sleep(1); shot(String(format: "01-onboarding-%02d", step))
            XCTAssertTrue(passModelPage(shots: true), "the model never finished, so setup could not go on")
            if step == 3 { app.swipeUp(); sleep(1); shot("01-onboarding-03b"); app.swipeUp(); sleep(1); shot("01-onboarding-03c") }
            app.buttons["onboarding.next"].tap()
            step += 1
        }
        XCTAssertGreaterThanOrEqual(step, 6, "expected welcome, methods, local AI, mic, keyboard, try")
        sleep(1); shot(String(format: "01-onboarding-%02d-try", step))
        app.buttons["onboarding.done"].tap()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 10))
        shot("05-home")
    }

    func test2DownloadVerifyTranscribe() {
        launch(onboarded: true)
        let model = ProcessInfo.processInfo.environment["FF_TEST_MODEL"] ?? "medium"
        tab("Models")
        let verified = element("verified.\(model)")
        if !verified.exists {
            let download = app.buttons["download.\(model)"]
            scrollTo(download)
            download.tap()
            XCTAssertTrue(element("progress.\(model)").waitForExistence(timeout: 30))
            sleep(3); shot("06-model-downloading")
            XCTAssertTrue(verified.waitForExistence(timeout: 1500), "model did not finish downloading and verifying")
        }
        let use = app.buttons["use.\(model)"]
        if use.exists { scrollTo(use); use.tap() }
        // Build 24: the full prepare screen shows only for a new install's first model, with no Dictate now
        // (only Go to Home); every later prepare stays on the model's card. FF_EXPECT_LOADER=1 or 0 asserts which.
        let loader = element("loader")
        let shown = loader.waitForExistence(timeout: 8)
        print("FFLOADER \(model) shown=\(shown) label=[\(shown && element("loader.label").exists ? element("loader.label").label : "")]")
        if shown {
            shot("06b-first-prepare")
            XCTAssertFalse(app.buttons["Dictate now"].exists, "the prepare screen still offers Dictate now")
            // A simulator prepares Ultra in about 15 s: the screen may be gone by now.
            XCTAssertTrue(app.buttons["loader.hide"].exists || !loader.exists, "no way Home from the prepare screen")
            print("FFLOADER buttons=\(app.buttons.allElementsBoundByIndex.prefix(12).map(\.label))")
            let deadline = Date().addingTimeInterval(660)
            while loader.exists && Date() < deadline { sleep(2) }
            XCTAssertFalse(loader.exists, "the prepare screen never went away")
        }
        if let expect = ProcessInfo.processInfo.environment["FF_EXPECT_LOADER"] {
            XCTAssertEqual(shown, expect == "1", "full prepare screen shown=\(shown), expected \(expect)")
        }
        XCTAssertFalse(element("stuck.\(model)").exists, "the model is marked stuck")
        tab("Dictate")
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["finishButton"].waitForExistence(timeout: 15))
        if ProcessInfo.processInfo.environment["FF_AUDIO_FILE"] != nil {
            // With the test clip the input reads "Test recording"; "MicrophoneBuiltIn" means this process never got it.
            XCTAssertTrue(app.staticTexts["Test recording"].waitForExistence(timeout: 5), "listening without the test clip")
        }
        sleep(4); shot("07-listening")
        sleep(8) // the clip is 11 s
        app.buttons["finishButton"].tap()
        let transcript = app.staticTexts["transcriptText"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 180))
        print("FFTRANSCRIPT " + transcript.label)
        XCTAssertTrue(transcript.label.lowercased().contains("ask not what your country"), transcript.label)
        let stats = app.staticTexts["statsText"]
        if stats.exists { print("FFSTATS " + stats.label) }
        shot("08-transcript")
        tab("Models")
        scrollTo(element("liveStats"))
        app.swipeUp(); sleep(2)
        shot("09-live-stats")
    }

    func test3Keyboard() {
        launch(onboarded: true)
        dictateWithKeyboard()
    }

    /// Build 23 (security): the keyboard's cancel still reaches Free Flow (its command carries the keyboard's nonce):
    /// the keyboard goes back to its keys, Free Flow stops listening, and nothing is typed.
    func testK2KeyboardCancel() {
        launch(onboarded: true)
        let session = app.buttons["sessionButton"]
        scrollTo(session)
        if session.label == "Start session" { session.tap(); sleep(2) }
        let field = element("tryField")
        scrollTo(field)
        field.tap()
        let mic = app.buttons["kb.mic"]
        XCTAssertTrue(showFreeFlowKeyboard(mic), "Free Flow keyboard did not appear")
        let before = (field.value as? String) ?? ""
        mic.tap()
        let cancel = app.buttons["kb.cancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "the keyboard did not show Listening")
        sleep(3); shot("k2-listening")
        cancel.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "the keyboard did not go back to its keys")
        sleep(3)
        XCTAssertFalse(app.buttons["kb.finishButton"].exists, "still listening after cancel")
        let value = (field.value as? String) ?? ""
        print("FFKEYBOARD cancel before=\(before.debugDescription) after=\(value.debugDescription)")
        XCTAssertEqual(value, before, "cancelled words were typed")
        shot("k2-cancelled")
    }

    /// Autocorrect with the bundled word list, typed on the Free Flow keyboard's own keys in the app's try field.
    /// "teh" then space must become "the"; "ask", a correct word, must stay as typed. Case is ignored because the
    /// keyboard may capitalise the first letter of the field.
    func test3bKeyboardAutocorrect() {
        launch(onboarded: true)
        let field = element("tryField")
        scrollTo(field)
        field.tap()
        XCTAssertTrue(showFreeFlowKeyboard(app.buttons["kb.mic"]), "Free Flow keyboard did not appear")
        let before = (field.value as? String) ?? ""
        for c in "teh ask " { app.descendants(matching: .any)[c == " " ? "key.space" : "key.\(c)"].firstMatch.tap() }
        sleep(1)
        let now = (field.value as? String) ?? ""
        let typed = now.hasPrefix(before) ? String(now.dropFirst(before.count)) : now
        print("FFAUTOCORRECT before=\(before.debugDescription) typed=\(typed.debugDescription)")
        shot("15-autocorrect")
        XCTAssertEqual(typed.lowercased(), "the ask ", "autocorrect in the keyboard")
    }

    /// Crash-loop guard. The gate first makes a C++ model the one in use, then plants the marker a GGUF load leaves
    /// when the app dies inside it (Application Support/FreeFlow/cpp-in-progress.json, the exact file
    /// Transcriber.crashGuard writes). The next launch must say so in one line and put dictation on Core ML; the
    /// launch after that has no line and stays on Core ML; the keyboard dictates. Without a planted marker the test
    /// fails at the first check (the gate's control run). Env FF_TEST_MODEL = the C++ model that was in use.
    func test8CppCrashFallsBackToCoreML() {
        let model = ProcessInfo.processInfo.environment["FF_TEST_MODEL"] ?? "parakeet-gguf-q4_0"
        // No relaunch here: this launch reads and removes the crash marker and shows the line only in this process,
        // so a second launch would erase what the test checks. It needs no arguments (the simulator is set up); the
        // dictation at the end runs on the next launch, which gets them.
        launch(onboarded: true, relaunchAfterInstall: false)
        let notice = element("cppCrashNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "no crash line: this launch saw no crash marker")
        print("FFCRASHNOTICE " + notice.label)
        shot("13-crash-notice")
        XCTAssertTrue(notice.label.contains("so dictation is back on Core ML"), notice.label)
        tab("Models")
        let use = app.buttons["use.\(model)"]
        scrollTo(use)
        XCTAssertTrue(use.exists, "\(model) is still the model in use")
        shot("14-models-after-crash")
        app.terminate()
        launch(onboarded: true)
        sleep(3)
        XCTAssertFalse(element("cppCrashNotice").exists, "the crash line came back on a launch with no crash")
        tab("Models")
        scrollTo(use)
        XCTAssertTrue(use.exists, "the next launch went back to \(model)")
        tab("Dictate")
        dictateWithKeyboard()
    }

    private func dictateWithKeyboard() {
        let session = app.buttons["sessionButton"]
        scrollTo(session)
        if session.label == "Start session" { session.tap(); sleep(2) }
        let field = element("tryField")
        scrollTo(field)
        field.tap()
        let mic = app.buttons["kb.mic"]
        XCTAssertTrue(showFreeFlowKeyboard(mic), "Free Flow keyboard did not appear")
        sleep(1); shot("10-keyboard")
        mic.tap()
        let finish = app.buttons["kb.finishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 15))
        sleep(4); shot("11-keyboard-listening")
        sleep(8)
        finish.tap()
        let deadline = Date().addingTimeInterval(180)
        var value = ""
        while Date() < deadline {
            value = (field.value as? String) ?? ""
            if value.lowercased().contains("country") { break }
            sleep(1)
        }
        print("FFKEYBOARD " + value)
        XCTAssertTrue(value.lowercased().contains("country"), value)
        shot("12-keyboard-inserted")
    }

    /// Types a sentence on the Free Flow keyboard with key haptics at Medium and Off, with Allow Full Access ON so
    /// the Medium runs really click (a keyboard cannot click without it). Levels run Medium, Off, Off, Medium so
    /// neither level always goes first. Every key must land. Prints the tap-to-text time per key (XCUITest's own
    /// overhead included, the same for both levels) and the keyboard's own report of what each click cost it.
    func test5KeyFeel() {
        XCTAssertTrue(allowFullAccess(), "could not turn on Allow Full Access for the Free Flow keyboard")
        let sentence = "the quick brown fox jumps over the lazy dog"
        var results: [String] = []
        var pooled: [String: [Double]] = [:]
        var drops: [(String, Int)] = []
        for (run, level) in ["Medium", "Off", "Off", "Medium"].enumerated() {
            launch(onboarded: true)
            setHaptics(level)
            app.terminate()
            launch(onboarded: true)
            let (landed, times, dropped) = typeOnKeyboard(sentence)
            pooled[level, default: []] += times
            drops.append((level, dropped.count))
            let (median, p95) = Self.medianP95(times)
            results.append(String(format: "run=%d haptics=%@ keys=%d landed=%d median=%.0fms p95=%.0fms", run + 1, level, sentence.count, landed, median, p95)
                           + " dropped=" + dropped.map(String.init).joined(separator: ",")
                           + " each=" + times.map { String(Int($0)) }.joined(separator: ","))
            if run == 0 { shot("18-keyboard-typed") }
            sleep(3)          // the keyboard saves what it measured 1.5 s after the last key
            app.terminate()   // the keyboard goes away and saves what it measured
            launch(onboarded: true)
            tab("Settings")
            let stats = element("keyFeelStats")
            scrollTo(stats)
            results.append("report(run=\(run + 1) \(level)): " + stats.label)
            XCTAssertFalse(stats.label.contains("Allow Full Access is off"), "Full Access did not reach the keyboard")
            if level == "Medium" { XCTAssertTrue(stats.label.contains("Clicks:"), "Medium did not click: \(stats.label)") }
            if run == 0 { shot("19-settings-keyboard") }
            app.terminate()
        }
        for level in ["Medium", "Off"] {
            let (median, p95) = Self.medianP95(pooled[level] ?? [])
            results.append(String(format: "pooled haptics=%@ taps=%d median=%.0fms p95=%.0fms", level, pooled[level]?.count ?? 0, median, p95))
        }
        launch(onboarded: true)
        setHaptics("Medium")
        results.forEach { print("FFKEYS " + $0) }
        for (level, n) in drops { XCTAssertEqual(n, 0, "\(n) dropped keys with haptics \(level)") }
    }

    /// Seen on an iPad (2026-10-29): iOS restarts the app when Allow Full Access changes, and setup then began
    /// again from its first page. Setup must come back on the step it was on.
    func test6SetupResume() {
        launch(onboarded: false)
        XCTAssertTrue(walkSetupToKeyboardStep(), "never reached the keyboard step")
        shot("30-setup-keyboard-step")
        app.terminate()   // what iOS does to the app when Full Access changes
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "NO"]
        app.launch()
        XCTAssertTrue(element("check.fullAccess").waitForExistence(timeout: 20),
                      "setup did not come back on the keyboard step after a restart")
        shot("31-setup-resumed")
    }

    /// The keyboard step sees Full Access as soon as the Free Flow keyboard opens on that step, with no restart.
    func test7SetupSeesFullAccess() {
        XCTAssertTrue(allowFullAccess(), "could not turn on Allow Full Access for the Free Flow keyboard")
        launch(onboarded: false, extra: ["-ffFreshKeyboard"])
        XCTAssertTrue(walkSetupToKeyboardStep(), "never reached the keyboard step")
        let row = element("check.fullAccess")
        XCTAssertEqual(row.value as? String, "not yet", "the keyboard was already seen, so this check would prove nothing")
        let box = element("setup.keyboardTry")
        scrollTo(box)
        XCTAssertTrue(box.exists, "no box on the keyboard step to open the keyboard in")
        box.tap()
        _ = showFreeFlowKeyboard(app.buttons["kb.mic"])
        let seen = expectation(for: NSPredicate(format: "value == %@", "done"), evaluatedWith: row)
        wait(for: [seen], timeout: 45)
        shot("32-setup-full-access-seen")
    }

    private func walkSetupToKeyboardStep() -> Bool {
        let next = app.buttons["onboarding.next"]
        for _ in 0..<8 {
            if element("check.fullAccess").waitForExistence(timeout: 2) { return true }
            guard next.waitForExistence(timeout: 10) else { return false }
            next.tap()
        }
        return element("check.fullAccess").exists
    }

    private static func medianP95(_ times: [Double]) -> (Double, Double) {
        let sorted = times.sorted()
        guard !sorted.isEmpty else { return (0, 0) }
        return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }

    /// Settings > General > Keyboard > Keyboards > Add New Keyboard... > Free Flow, like a person does.
    private func addFreeFlowKeyboard() -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        let back = settings.navigationBars.buttons["BackButton"].firstMatch
        var hops = 0
        while back.waitForExistence(timeout: 2) && hops < 8 { back.tap(); sleep(1); hops += 1 }
        func open(_ e: XCUIElement) -> Bool {
            guard e.waitForExistence(timeout: 8) else { return false }
            var n = 0
            while !e.isHittable && n < 10 { settings.swipeUp(); n += 1 }
            e.tap(); sleep(1)
            return true
        }
        func row(_ label: String) -> XCUIElement {
            // Rows first, then any element with that label (the Settings home page is not all cells), as allowFullAccess does.
            let match = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
            let cell = settings.cells.matching(match).element(boundBy: 0)
            return cell.waitForExistence(timeout: 8) ? cell : settings.descendants(matching: .any).matching(match).element(boundBy: 0)
        }
        for label in ["General", "Keyboard", "Keyboards"] where !open(row(label)) {
            print("FFSETUP missing \(label): " + settings.debugDescription.prefix(6000))
            return false
        }
        let ours = row("Free Flow")
        if ours.waitForExistence(timeout: 3) {
            print("FFSETUP Free Flow keyboard: already added")
            settings.terminate()
            return true
        }
        guard open(settings.cells["AddNewKeyboard"].firstMatch) else {
            print("FFSETUP no Add New Keyboard: " + settings.debugDescription.prefix(6000))
            return false
        }
        guard open(row("Free Flow")) else {
            print("FFSETUP Free Flow not offered: " + settings.debugDescription.prefix(6000))
            return false
        }
        let added = row("Free Flow").waitForExistence(timeout: 8)
        print("FFSETUP Free Flow keyboard: " + (added ? "added" : "not added"))
        settings.terminate()
        return added
    }

    private func allowFullAccess() -> Bool { setFullAccess(true) }

    /// Settings > General > Keyboard > Keyboards > Free Flow > Allow Full Access, then Allow, like a person does
    /// (or off, with `on` false).
    private func setFullAccess(_ on: Bool) -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        // Settings reopens on the last page it showed: go back to its first page before walking the path.
        let back = settings.navigationBars.buttons["BackButton"].firstMatch
        var hops = 0
        while back.waitForExistence(timeout: 2) && hops < 8 { back.tap(); sleep(1); hops += 1 }
        func open(_ label: String) -> Bool {
            // Rows first: a page title can carry the same word (the Keyboard page is titled "Keyboards").
            let match = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
            let row = settings.cells.matching(match).element(boundBy: 0)
            let e = row.waitForExistence(timeout: 8) ? row : settings.descendants(matching: .any).matching(match).element(boundBy: 0)
            guard e.exists else { return false }
            var n = 0
            while !e.isHittable && n < 10 { settings.swipeUp(); n += 1 }
            e.tap(); sleep(1)
            return true
        }
        for label in ["General", "Keyboard", "Keyboards", "Free Flow"] {
            if !open(label) {
                print("FFSETTINGS missing \(label): " + settings.debugDescription.prefix(6000))
                return false
            }
        }
        let toggle = settings.switches["Allow Full Access"].firstMatch
        guard toggle.waitForExistence(timeout: 8) else {
            print("FFSETTINGS no switch: " + settings.debugDescription.prefix(6000))
            return false
        }
        let want = on ? "1" : "0"
        if (toggle.value as? String) != want {
            toggle.tap()
            if (toggle.value as? String) != want, !settings.alerts.firstMatch.waitForExistence(timeout: 2) {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()   // the switch itself, not its row
            }
            let allow = settings.alerts.buttons["Allow"].firstMatch
            if on, allow.waitForExistence(timeout: 5) { allow.tap() }
            sleep(1)
        }
        let now = (toggle.value as? String) == "1"
        print("FFSETTINGS Allow Full Access = \(now ? "on" : "off")")
        settings.terminate()
        return now == on
    }

    /// Settings > Apps > Free Flow > Microphone, on or off, like a person does.
    private func setMicrophone(_ on: Bool) -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        let back = settings.navigationBars.buttons["BackButton"].firstMatch
        var hops = 0
        while back.waitForExistence(timeout: 2) && hops < 8 { back.tap(); sleep(1); hops += 1 }
        for label in ["Apps", "Free Flow"] {
            let match = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
            // On iPhone each Settings row is a button inside an unlabelled cell; on iPad the cell carries the label.
            let button = settings.buttons.matching(match).element(boundBy: 0)
            let cell = settings.cells.matching(match).element(boundBy: 0)
            // Apps sits low on the first page and Free Flow down the Apps list: scroll like a person until it shows.
            var n = 0
            while !(button.waitForExistence(timeout: n == 0 ? 4 : 1) || cell.exists) && n < 14 { settings.swipeUp(); n += 1 }
            let e = button.exists ? button : cell
            guard e.exists else { print("FFSETTINGS missing \(label): " + settings.debugDescription.prefix(6000)); return false }
            n = 0
            while !e.isHittable && n < 12 { settings.swipeUp(); n += 1 }
            e.tap(); sleep(1)
        }
        let toggle = settings.switches["Microphone"].firstMatch
        guard toggle.waitForExistence(timeout: 8) else { print("FFSETTINGS no Microphone switch: " + settings.debugDescription.prefix(6000)); return false }
        let want = on ? "1" : "0"
        if (toggle.value as? String) != want {
            toggle.tap()
            if (toggle.value as? String) != want { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            sleep(1)
        }
        let now = (toggle.value as? String) == "1"
        print("FFSETTINGS Microphone = \(now ? "on" : "off")")
        settings.terminate()
        return now == on
    }

    /// Back to Free Flow after Settings, like a person: it is still running, or iOS ended it (it does when Full Access or
    /// the microphone changes) and it opens where setup was.
    private func comeBack() {
        if app.state == .runningBackground || app.state == .runningBackgroundSuspended {
            app.activate()
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-onboarded", "NO"]
            app.launch()
        }
        sleep(2)
    }

    /// Build 19 (a repeat report from an iPad: setup said a permission was not given while dictation worked). Setup
    /// shows the true state of each permission it checks, with no restart: the microphone from iOS each time Free Flow
    /// is active, the keyboard rows from the keyboard each time it opens. Grant each the way a person does, come back,
    /// check; revoke, come back, check.
    /// App Store kit (build 19): the store frames, from the real app on this simulator with the keyboard set up. The
    /// words are what the speech model and Apple Intelligence wrote from the test clip; nothing is typed in or edited.
    func testStoreKit() {
        launch(onboarded: true)
        // History starts empty, so the History frame shows only this run's dictations.
        tab("History")
        let clear = app.buttons["Clear all"].firstMatch
        if clear.waitForExistence(timeout: 3) {
            clear.tap()
            let del = app.buttons["Delete all"].firstMatch
            if del.waitForExistence(timeout: 5) { del.tap() }
            sleep(1)
        }
        tab("Settings")
        let writer = app.switches["settings.appleWriter"].firstMatch
        XCTAssertTrue(writer.waitForExistence(timeout: 10), "no Apple Intelligence switch")
        if (writer.value as? String) != "1" { writer.tap(); sleep(1) }
        print("FFKIT writer switch=\(writer.value ?? "") state=\(element("settings.writerState").label)")
        sleep(1); shot("kit-3-writing")
        app.buttons["settings.whereItRuns"].tap()
        XCTAssertTrue(element("whereItRuns").waitForExistence(timeout: 10))
        sleep(3); shot("kit-4-where")
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)
        let layouts = app.buttons["settings.keyLayout"].firstMatch
        scrollTo(layouts)
        layouts.tap(); sleep(2); shot("kit-7-layouts")
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)

        // Dictate into Messages with the Free Flow keyboard, in Formal, then the same words in Excited.
        tab("Dictate")
        startWarmSession()
        let host = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        host.launch()
        XCTAssertTrue(host.wait(for: .runningForeground, timeout: 10), "Messages did not open")
        sleep(2)
        for label in ["Continue", "Not Now", "Done", "OK"] {
            let b = host.buttons[label].firstMatch
            if b.exists && b.isHittable { b.tap(); sleep(1) }
        }
        let compose = host.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'compose' OR label CONTAINS[c] 'new message' OR identifier CONTAINS[c] 'compose'")).firstMatch
        if compose.waitForExistence(timeout: 3) && compose.isHittable { compose.tap(); sleep(2) }
        let field = host.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'messageBodyField' OR placeholderValue CONTAINS[c] 'message'")).firstMatch
        if !field.waitForExistence(timeout: 4) {
            // No compose button found: open the first conversation, like a person replying.
            let chat = host.collectionViews["ConversationList"].cells.firstMatch
            if chat.exists { chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2) }
        }
        let body = field.waitForExistence(timeout: 8) ? field
            : (host.textViews.count > 0 ? host.textViews.element(boundBy: host.textViews.count - 1) : host.textFields.firstMatch)
        if !body.exists { print("FFKIT Messages tree: " + host.debugDescription) }
        XCTAssertTrue(body.exists, "no message field")
        XCTAssertTrue(showFreeFlowKeyboard(in: host, tapping: body), "Free Flow keyboard did not appear")
        let style = host.buttons["kb.style"]
        // One tap moves one style on; wait for the key to show the new one before the next tap.
        // The key reads "Style, <name>" to VoiceOver.
        func pickStyle(_ name: String) {
            var hops = 0
            while !style.label.hasSuffix(name) && hops < 6 {
                let before = style.label
                style.tap()
                let deadline = Date().addingTimeInterval(3)
                while style.label == before && Date() < deadline { usleep(200_000) }
                hops += 1
            }
            print("FFKIT style=\(style.label)")
        }
        pickStyle("Formal.")
        let clip = Double(ProcessInfo.processInfo.environment["FF_STORE_CLIP_SECONDS"] ?? "6") ?? 6
        func dictate(_ name: String?) -> String {
            let before = (body.value as? String) ?? ""
            host.buttons["kb.mic"].tap()
            let finish = host.buttons["kb.finishButton"]
            XCTAssertTrue(finish.waitForExistence(timeout: 15), "the keyboard is not listening")
            sleep(5)
            if let name { shot(name) }
            sleep(UInt32(max(1, clip.rounded(.up) - 4)))
            finish.tap()
            if let name { usleep(400_000); shot(name + "-writing") }
            var value = before
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                value = (body.value as? String) ?? ""
                if value != before && value.split(separator: " ").count > before.split(separator: " ").count + 2 { sleep(2); break }
                sleep(1)
            }
            return (body.value as? String) ?? ""
        }
        let first = dictate("kit-1-dictating")
        print("FFKIT formal landed=" + first)
        sleep(1); shot("kit-2-result")
        let ret = host.buttons["key.return"].firstMatch
        if ret.exists { ret.tap() }
        pickStyle("Excited!")
        let both = dictate(nil)
        print("FFKIT excited landed=" + both)
        sleep(1); shot("kit-6-styles")
        pickStyle("Formal.")

        app.activate()
        tab("History")
        sleep(2); shot("kit-5-history")

        app.terminate()
        storeSetupShot()
    }

    /// The setup frame alone (the last part of testStoreKit).
    func testStoreKitSetup() { storeSetupShot() }

    /// Setup, on the keyboard step, after the keyboard opened once: both rows checked.
    private func storeSetupShot() {
        launch(onboarded: false)
        XCTAssertTrue(walkSetupToKeyboardStep(), "never reached the keyboard step")
        let box = element("setup.keyboardTry")
        scrollTo(box)
        box.tap()
        _ = showFreeFlowKeyboard(app.buttons["key.q"])
        let full = element("check.fullAccess")
        wait(for: [expectation(for: NSPredicate(format: "value == 'done'"), evaluatedWith: full)], timeout: 10)
        showKeyboardRows()
        app.swipeDown(); sleep(1)   // to the top of the page, so the step's title shows above the rows
        shot("kit-8-setup")
    }

    /// Puts the keyboard away and scrolls back up to the two keyboard rows, so a screenshot shows what they say.
    private func showKeyboardRows() {
        let hide = app.buttons["kb.hide"]
        if hide.exists && hide.isHittable { hide.tap(); sleep(1) }
        let row = element("check.keyboardAdded")
        var n = 0
        while !(row.exists && row.isHittable) && n < 6 { app.swipeDown(); n += 1 }
        sleep(1)
    }

    func test9bModelMissing() {
        launch(onboarded: true)
        tab("Dictate")
        let state = element("modelState")
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let label = state.label
        print("FFMISSING home: " + label)
        XCTAssertTrue(label.contains("missing"), "Home does not say the model is missing: \(label)")
        shot("44-model-missing-home")
        app.buttons["micButton"].tap()
        let error = element("errorText")
        XCTAssertTrue(error.waitForExistence(timeout: 10), "a dictation with no model showed no message")
        print("FFMISSING dictate: " + error.label)
        XCTAssertTrue(error.label.contains("Models"), "the message does not point to Models: \(error.label)")
        shot("45-model-missing-dictate")
        let open = app.buttons["home.openModels"]
        XCTAssertTrue(open.exists, "no way to the Models page from Home")
        open.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download.'")).firstMatch.waitForExistence(timeout: 10),
                      "Open Models did not show a download")
        shot("46-model-missing-models")
    }

    func test9PermissionsTrueState() {
        _ = setFullAccess(false)
        launch(onboarded: false, extra: ["-ffFreshKeyboard"])
        let next = app.buttons["onboarding.next"]
        let mic = element("check.mic")
        for _ in 0..<8 where !mic.exists { if next.waitForExistence(timeout: 5) && next.isEnabled { next.tap(); sleep(1) } }
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "never reached the microphone page (a model must be downloaded first)")
        if app.buttons["allowMic"].exists {
            app.buttons["allowMic"].tap()
            let allow = springboard.alerts.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        wait(for: [expectation(for: NSPredicate(format: "value == 'done'"), evaluatedWith: mic)], timeout: 10)
        shot("40-perm-mic-allowed")
        XCTAssertTrue(walkSetupToKeyboardStep(), "never reached the keyboard step")
        let added = element("check.keyboardAdded"), full = element("check.fullAccess")
        XCTAssertEqual(full.value as? String, "not yet")

        // Grant: add the keyboard and turn on Full Access in Settings, come back, open the keyboard once.
        XCTAssertTrue(addFreeFlowKeyboard(), "could not add the Free Flow keyboard in Settings")
        XCTAssertTrue(setFullAccess(true), "could not turn on Allow Full Access")
        comeBack()
        XCTAssertTrue(full.waitForExistence(timeout: 20), "setup did not come back on the keyboard step")
        print("FFPERM granted, before the keyboard opens: added=\(added.value ?? "") full=\(full.value ?? "")")
        XCTAssertNotEqual(full.value as? String, "done", "no report from the keyboard yet, so 'done' would be a guess")
        let box = element("setup.keyboardTry")
        scrollTo(box)
        box.tap()
        _ = showFreeFlowKeyboard(app.buttons["key.q"])
        wait(for: [expectation(for: NSPredicate(format: "value == 'done'"), evaluatedWith: full),
                   expectation(for: NSPredicate(format: "value == 'done'"), evaluatedWith: added)], timeout: 10)
        shot("41-perm-keyboard-granted")
        showKeyboardRows()
        shot("41b-perm-rows-granted")

        // Revoke Full Access, come back: not 'done' before the keyboard opens, 'not yet' once it has.
        XCTAssertTrue(setFullAccess(false), "could not turn off Allow Full Access")
        comeBack()
        XCTAssertTrue(full.waitForExistence(timeout: 20), "setup did not come back on the keyboard step")
        print("FFPERM revoked, before the keyboard opens: added=\(added.value ?? "") full=\(full.value ?? "")")
        XCTAssertNotEqual(full.value as? String, "done", "Full Access was turned off, and setup still says done")
        scrollTo(box)
        box.tap()
        _ = showFreeFlowKeyboard(app.buttons["key.q"])
        wait(for: [expectation(for: NSPredicate(format: "value == 'not yet'"), evaluatedWith: full),
                   expectation(for: NSPredicate(format: "value == 'done'"), evaluatedWith: added)], timeout: 10)
        shot("42-perm-full-access-off")
        showKeyboardRows()
        shot("42b-perm-rows-full-access-off")

        // Revoke the microphone, come back: the microphone page says it is off.
        XCTAssertTrue(setMicrophone(false), "could not turn off the microphone in Settings")
        comeBack()
        let backButton = app.buttons["onboarding.back"]
        for _ in 0..<6 where !mic.exists { if backButton.waitForExistence(timeout: 5) { backButton.tap(); sleep(1) } }
        wait(for: [expectation(for: NSPredicate(format: "value == 'turned off'"), evaluatedWith: mic)], timeout: 10)
        shot("43-perm-mic-off")

        // Put both back for the tests after this one.
        XCTAssertTrue(setMicrophone(true))
        XCTAssertTrue(setFullAccess(true))
    }

    /// iOS sometimes brings up its own keyboard first. Like a person, tap the globe until Free Flow's shows.
    private func showFreeFlowKeyboard(_ key: XCUIElement) -> Bool {
        if key.waitForExistence(timeout: 8) { return true }
        return switchToFreeFlow(in: app, key: key)
    }

    private func setHaptics(_ level: String) {
        tab("Settings")
        let picker = element("set.keyHaptics")
        scrollTo(picker)
        picker.tap()
        let option = app.buttons[level].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "no \(level) option")
        option.tap()
        sleep(1)
    }

    /// Taps each character on the keyboard and waits for that character to reach the field. Each key is judged on
    /// its own (the field grew by exactly that character), so one dropped key does not count every later key as
    /// dropped. Returns how many landed, the tap-to-text time of each landed key in ms (XCUITest's own overhead
    /// included, the same for both levels) and the indexes of keys that did not land.
    private func typeOnKeyboard(_ text: String) -> (Int, [Double], [Int]) {
        tab("Dictate")
        let field = element("tryField")
        scrollTo(field)
        field.tap()
        XCTAssertTrue(showFreeFlowKeyboard(app.buttons["key.q"]), "Free Flow keyboard did not appear")
        sleep(1)
        var current = "", landed = 0, times: [Double] = [], dropped: [Int] = []
        for (i, ch) in text.enumerated() {
            let key = app.buttons[ch == " " ? "key.space" : "key.\(ch)"]
            let want = current + String(ch)
            let t0 = Date()
            key.tap()
            let deadline = Date().addingTimeInterval(4)
            var ok = false
            while Date() < deadline {
                if (field.value as? String) == want { ok = true; break }
                usleep(5_000)
            }
            if ok {
                landed += 1
                times.append(Date().timeIntervalSince(t0) * 1000)
            } else {
                dropped.append(i)
            }
            let now = (field.value as? String) ?? ""
            current = now.hasPrefix("Tap here") ? "" : now    // an empty field reports its placeholder
        }
        return (landed, times, dropped)
    }

    func test4Screens() {
        launch(onboarded: true)
        tab("Dictionary")
        let word = app.textFields["dictWord"]
        if word.waitForExistence(timeout: 5) {
            word.tap(); word.typeText("MASHBOX")
            // Build 10: the word only. No "sounds like" field (no hard replace).
            XCTAssertFalse(app.textFields["dictHeard"].exists)
            app.buttons["dictAdd"].tap()
        }
        shot("13-dictionary")
        tab("History"); shot("14-history")
        tab("Settings"); shot("15-settings")
        let about = app.buttons["About and credits"].firstMatch
        var n = 0
        while !about.isHittable && n < 8 { app.swipeUp(); n += 1 }
        about.tap(); sleep(1); shot("16-about")
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)
        let privacy = app.buttons["Privacy"].firstMatch
        scrollTo(privacy); privacy.tap(); sleep(1); shot("17-privacy")
    }
}

/// Stats cards and page, driven through the real UI. Numbers come only from real dictations of the test clip
/// (FF_AUDIO_FILE) or from history the previous build wrote; nothing is seeded. FF_EXPECT says which state the
/// device is in: "empty" (fresh install or after Reset), "history" (upgraded from a build without stats), or "any".
final class StatsUITests: XCTestCase {
    var app: XCUIApplication!
    let kinds = ["words", "streak", "speed", "saved", "device"]
    var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = false }

    private func launch(size: String = "UICTContentSizeCategoryL") {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES", "-UIPreferredContentSizeCategoryName", size]
        if let file = env["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Taps a tab and checks it took: on a loaded Mac a tap can be swallowed.
    private func tab(_ name: String) {
        for _ in 0..<4 {
            let bar = app.tabBars.buttons[name]
            let button = bar.exists ? bar : app.buttons[name].firstMatch
            if button.isSelected { return }
            button.tap()
            sleep(2)
            if button.isSelected { return }
        }
        XCTFail("tab \(name) did not open")
    }

    private func reveal(_ e: XCUIElement, max: Int = 10) {
        var n = 0
        while !(e.exists && e.isHittable) && n < max { app.swipeUp(); n += 1 }
    }

    private func words(_ label: String) -> Int {
        Int(label.prefix { $0.isNumber || $0 == "," }.replacingOccurrences(of: ",", with: "")) ?? -1
    }

    /// Swipes through the five Home cards; checks each has a spoken label; returns the labels.
    @discardableResult
    private func walkCards(_ prefix: String) -> [String: String] {
        tab("Dictate")
        let first = element("stats.card.words")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "stats cards are not on Home")
        let row = element("stats.row")
        for _ in 0..<5 where row.exists && row.isHittable && !first.isHittable { row.swipeRight(); usleep(400_000) }
        reveal(first)
        var labels: [String: String] = [:]
        for (i, kind) in kinds.enumerated() {
            let card = element("stats.card.\(kind)")
            if i > 0 {
                var n = 0
                while !card.isHittable && n < 3 { element("stats.card.\(kinds[i - 1])").swipeLeft(); sleep(1); n += 1 }
            }
            XCTAssertTrue(card.exists && card.isHittable, "card \(kind) not reachable by swiping")
            labels[kind] = card.label
            print("FFSTATSUI \(prefix) \(kind): \(card.label)")
            XCTAssertGreaterThan(card.label.count, 20, "card \(kind) needs a VoiceOver label")
            shot("\(prefix)-home-\(i + 1)-\(kind)")
        }
        return labels
    }

    private func openPage(_ prefix: String) {
        let all = element("stats.all")
        reveal(all)
        all.tap()
        XCTAssertTrue(element("stats.page").waitForExistence(timeout: 10), "Stats page did not open")
        sleep(1); shot("\(prefix)-page-1")
        for n in 2...5 { app.swipeUp(); sleep(1); shot("\(prefix)-page-\(n)") }
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
    }

    private func check(_ labels: [String: String], expect: String) {
        let w = labels["words"] ?? "", sp = labels["speed"] ?? "", st = labels["streak"] ?? "", dev = labels["device"] ?? ""
        XCTAssertTrue(dev.contains("0 bytes of audio or text sent"), dev)
        XCTAssertFalse(labels.values.joined().lowercased().contains("top "), "no comparisons with other people")
        switch expect {
        case "empty":
            XCTAssertTrue(w.hasPrefix("0 words dictated. Your first dictation starts the count."), w)
            XCTAssertTrue(st.hasPrefix("Day streak: 0 days."), st)
            XCTAssertTrue(sp.hasPrefix("Your speaking speed shows after your first dictation."), sp)
        case "history":
            XCTAssertGreaterThan(words(w), 0, "history was not counted: \(w)")
            XCTAssertTrue(sp.contains("after your next dictation"), "history has no audio, so no speed yet: \(sp)")
            XCTAssertTrue(st.hasPrefix("Day streak: 1 day."), st)
        default:
            XCTAssertGreaterThan(words(w), 0, w)
            XCTAssertTrue(sp.contains("words per minute"), sp)
            XCTAssertTrue(dev.contains("real time"), dev)
        }
    }

    /// Home cards and the Stats page as the device has them now, at Dynamic Type L, then at Accessibility L.
    func testS1Look() {
        let expect = env["FF_EXPECT"] ?? "any"
        let tag = env["FF_SHOT_TAG"] ?? expect
        launch()
        check(walkCards("\(tag)-L"), expect: expect)
        openPage("\(tag)-L")
        if expect == "history" {
            launch()
            let all = element("stats.all"); reveal(all); all.tap()
            let note = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "counted from your history")).firstMatch
            reveal(note)
            XCTAssertTrue(note.exists, "the page should say earlier dictations came from history")
            print("FFSTATSUI note: \(note.label)")
        }
        app.terminate()
        launch(size: "UICTContentSizeCategoryAccessibilityL")
        walkCards("\(tag)-AXL")
        openPage("\(tag)-AXL")
    }

    /// One real dictation of the clip: words go up by what was written, speed and model speed appear.
    func testS2Dictate() {
        launch()
        let before = words(walkCards("pre")["words"] ?? "")
        let model = env["FF_TEST_MODEL"] ?? "medium"
        tab("Models")
        let verified = element("verified.\(model)")
        if !verified.exists {
            let download = app.buttons["download.\(model)"]
            reveal(download)
            download.tap()
            XCTAssertTrue(verified.waitForExistence(timeout: 1500), "model did not finish downloading and verifying")
        }
        let use = app.buttons["use.\(model)"]
        if use.exists { reveal(use); use.tap() }
        tab("Dictate")
        app.swipeDown(); app.swipeDown()
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["finishButton"].waitForExistence(timeout: 15))
        sleep(12)  // the clip is 11 s
        app.buttons["finishButton"].tap()
        let transcript = app.staticTexts["transcriptText"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 180))
        print("FFSTATSUI transcript: \(transcript.label)")
        let labels = walkCards("post")
        let after = words(labels["words"] ?? "")
        let written = transcript.label.split { $0 == " " || $0 == "\n" }.count
        print("FFSTATSUI words before=\(before) after=\(after) transcript tokens=\(written)")
        XCTAssertEqual(after - before, written, "the words card must go up by the words just written")
        check(labels, expect: "any")
    }

    /// Settings > Reset stats goes to zero and stays at zero after a relaunch (history is not counted again).
    func testS3Reset() {
        launch()
        tab("Settings")
        let reset = element("set.resetStats")
        reveal(reset)
        reset.tap()
        let confirm = app.buttons["set.resetStats.confirm"].exists ? app.buttons["set.resetStats.confirm"] : app.buttons["Reset stats"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("reset-confirm")
        confirm.tap()
        sleep(1)
        XCTAssertTrue(walkCards("reset")["words"]!.hasPrefix("0 words"))
        app.terminate()
        launch()
        XCTAssertTrue(walkCards("relaunch")["words"]!.hasPrefix("0 words"), "history must not be counted again after Reset")
    }
}

// MARK: Long recordings (2026-10-29: a long recording was missed on an iPad, and recording kept stopping
// mid-dictation).
extension FreeFlowUITests {
    /// Records FF_LONG_SECONDS of real speech (FF_AUDIO_FILE, fed FF_AUDIO_FEED_SPEED times faster than real time) through
    /// one path, FF_LONG_MODE: app = the Dictate button; keyboard = the Free Flow keyboard in Free Flow's own field;
    /// host = the Free Flow keyboard in Contacts with Free Flow in the background (warm session). Model FF_TEST_MODEL.
    /// The recording must stay on until Finish (checked every 20 s), and the text must come back whole where the
    /// dictation started: 90-110% of the file's FF_LONG_WORDS reference words. Prints FFLONG lines for the gate log.
    func testL1LongRecording() {
        let env = ProcessInfo.processInfo.environment
        let mode = env["FF_LONG_MODE"] ?? "app"
        let seconds = Double(env["FF_LONG_SECONDS"] ?? "") ?? 300
        let speed = max(1, Double(env["FF_AUDIO_FEED_SPEED"] ?? "") ?? 1)
        let expected = Int(env["FF_LONG_WORDS"] ?? "") ?? 0
        let model = env["FF_TEST_MODEL"] ?? "medium"
        launch(onboarded: true, extra: ["-activeModel", model])
        let recordFor = seconds / speed + 4
        // Simulator CPU: Core ML Parakeet ~11x, C++ Parakeet ~6x real time. FF_LONG_WAIT caps it for red runs.
        let waitText = Double(env["FF_LONG_WAIT"] ?? "") ?? (240 + seconds / 2)
        var field: XCUIElement
        var finish: XCUIElement
        var hostApp: XCUIApplication?
        // The field's text before this dictation: only text that differs from it can pass (an earlier C++ long
        // run's "pass" read the previous run's words still sitting in Contacts' search field).
        var before = ""
        switch mode {
        case "app":
            tab("Dictate")
            app.buttons["micButton"].tap()
            finish = app.buttons["finishButton"]
            field = app.staticTexts["transcriptText"]
        case "host":
            startWarmSession()
            XCTAssertNotEqual(app.buttons["sessionButton"].label, "Start session", "the warm session did not start")
            XCUIDevice.shared.press(.home)
            sleep(2)
            let host = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
            host.launch()
            field = host.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 15), "Contacts has no search field")
            XCTAssertTrue(showFreeFlowKeyboard(in: host, tapping: field), "Free Flow keyboard did not appear in Contacts")
            let clear = field.buttons["Clear text"]
            if clear.exists { clear.tap(); sleep(1) }
            before = (field.value as? String) ?? ""
            XCTAssertLessThan(before.split(whereSeparator: \.isWhitespace).count, 3, "Contacts' search field still holds old text")
            hostApp = host
            host.buttons["kb.mic"].tap()
            finish = host.buttons["kb.finishButton"]
        default:
            startWarmSession()
            field = element("tryField")
            scrollTo(field)
            field.tap()
            let mic = app.buttons["kb.mic"]
            XCTAssertTrue(showFreeFlowKeyboard(mic), "Free Flow keyboard did not appear")
            mic.tap()
            finish = app.buttons["kb.finishButton"]
        }
        XCTAssertTrue(finish.waitForExistence(timeout: 15), "\(mode): listening did not start")
        if mode == "app" {
            XCTAssertTrue(app.staticTexts["Test recording"].waitForExistence(timeout: 5), "listening without the test clip")
        }
        let start = Date()
        var blips = 0
        sleep(3); shot("L1-\(mode)-listening")
        while Date().timeIntervalSince(start) < recordFor {
            sleep(UInt32(min(20, max(1, recordFor - Date().timeIntervalSince(start)))))
            let at = Int(Date().timeIntervalSince(start))
            // r10: a host stall made the app miss heartbeats; the keyboard said "not answering" while the app kept
            // recording. It must come back to Listening by itself (KeyboardLiveRule); every such blip is printed.
            if !finish.exists {
                shot("L1-\(mode)-blip\(blips + 1)")
                if finish.waitForExistence(timeout: 20) {
                    blips += 1
                    print("FFLONG BLIP \(blips) mode=\(mode) at \(at) s: Finish came back within 20 s")
                    continue
                }
            }
            if !finish.exists {
                shot("L1-\(mode)-stopped")
                print("FFLONG STOPPED mode=\(mode) model=\(model) after \(at) s of \(Int(recordFor)) s (audio \(Int(Double(at) * speed)) s)")
                XCTFail("\(mode): the recording stopped by itself after \(at) s")
                return
            }
        }
        if mode == "host" { XCTAssertNotEqual(app.state, .runningForeground, "Free Flow came to the front during the dictation") }
        print("FFLONG BLIPS \(blips) mode=\(mode) model=\(model)")
        finish.tap()
        let tapped = Date()
        // FF_LONG_RESHOW=1 (host): leave Contacts right after Finish and come back, so the text has to land in a keyboard
        // iOS shows again (often a new keyboard instance) after a dictation longer than 10 minutes.
        if let host = hostApp, env["FF_LONG_RESHOW"] == "1" {
            sleep(1)
            XCUIDevice.shared.press(.home)
            sleep(3)
            host.activate()
            if !host.buttons["kb.mic"].waitForExistence(timeout: 6) { field.tap() }
            print("FFLONG reshow keyboard_back=\(host.buttons["kb.mic"].waitForExistence(timeout: 6)) after \(Int(Date().timeIntervalSince(tapped))) s")
            shot("L1-\(mode)-reshown")
        }
        var text = ""
        let read = { mode == "app" ? (field.exists ? field.label : "") : ((field.value as? String) ?? "") }
        while Date().timeIntervalSince(tapped) < waitText {
            text = read()
            if text != before, text.split(whereSeparator: \.isWhitespace).count > 20 { sleep(3); break }
            sleep(2)
        }
        text = read()
        XCTAssertNotEqual(text, before, "\(mode): the field did not change")
        let words = text.split(whereSeparator: \.isWhitespace)
        let ratio = expected > 0 ? Double(words.count) / Double(expected) : 0
        print(String(format: "FFLONG mode=%@ model=%@ audio=%.0fs speed=%.0fx words=%d/%d ratio=%.3f text_after_finish=%.1fs",
                     mode, model, seconds, speed, words.count, expected, ratio, Date().timeIntervalSince(tapped)))
        print("FFLONG tail: " + words.suffix(16).joined(separator: " "))
        shot("L1-\(mode)-done")
        XCTAssertGreaterThan(words.count, 0, "\(mode): no text came back")
        if expected > 0 { XCTAssertTrue(ratio >= 0.9 && ratio <= 1.1, "\(mode): \(words.count) words of \(expected)") }
    }
}

/// Settings shows the keyboard layout near the top with three small previews (L4 first, the default);
/// a preview opens the large view with Use.
final class KeyboardRowUITests: XCTestCase {
    let app = XCUIApplication()
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Works from whatever layout the sim already uses (a saved choice stays, so an older sim may not be on Classic):
    /// opens a preview that is not in use, uses it, checks the row, then puts the starting layout back.
    func testKR1KeyboardRowPreviewsAndUse() {
        app.launchArguments += ["-onboarded", "YES"]
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap(); sleep(2)
        // Build 18: Classic is the default and comes first; L4 stays in the row.
        let classic = el("layoutMini.classic")
        XCTAssertTrue(classic.waitForExistence(timeout: 5), "the Keyboard row's previews")
        XCTAssertTrue(el("layoutMini.l4").exists)
        XCTAssertLessThan(classic.frame.minX, el("layoutMini.l4").frame.minX, "Classic comes first")
        XCTAssertTrue(classic.isHittable)
        let startTitle = el("settings.keyLayout.current").label
        let inUse = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'layoutMini.' AND value == 'In use'")).firstMatch
        XCTAssertTrue(inUse.exists, "one preview is marked In use")
        let startId = inUse.identifier
        let targetId = startId == "layoutMini.classic" ? "layoutMini.l4" : "layoutMini.classic"
        print("KR1 start=\(startId) '\(startTitle)' target=\(targetId)")
        shot("kr1-1-settings-row")
        // The preview in use opens its large view marked In use.
        el(startId).tap(); sleep(1)
        XCTAssertTrue(el("layoutDetail.inUse").waitForExistence(timeout: 5), "large view of the layout in use")
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        // Another preview opens its large view with Use.
        el(targetId).tap(); sleep(1)
        XCTAssertTrue(el("layoutDetail.use").waitForExistence(timeout: 5), "large view with Use")
        shot("kr1-2-detail-other")
        el("layoutDetail.use").tap(); sleep(1)
        XCTAssertTrue(el("layoutDetail.inUse").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        XCTAssertEqual(el("settings.keyLayout.current").label, targetId == "layoutMini.l4" ? "L4 Delete after L" : "Classic")
        shot("kr1-3-settings-after-use")
        // Put the starting layout back.
        el(startId).tap(); sleep(1)
        XCTAssertTrue(el("layoutDetail.use").waitForExistence(timeout: 5)); el("layoutDetail.use").tap(); sleep(1)
        XCTAssertTrue(el("layoutDetail.inUse").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        XCTAssertEqual(el("settings.keyLayout.current").label, startTitle)
    }
}


/// Build 18 (LFM3 dropped; Apple Intelligence is the writer, optional). Dictates the test clip
/// and checks the readout: Apple's model wrote it, or the text went in as heard and the readout says why (Apple
/// Intelligence not on, device not eligible, model not ready). The step never runs past its limit (WritingBudget:
/// 3 s + 1 s per 20 words, at most 15 s). Where Apple's model wrote, the clip's swears and apologies survive
/// (FF_WRITER_WORDS, comma list; default for swear.wav). Settings › Writing › Where it runs names the same writer state.
extension FreeFlowUITests {
    func testW1WriterApple() {
        launch(onboarded: true)
        let first = dictateForReadout(previous: nil)
        print("FFW1 apple text=" + first.text)
        print("FFW1 apple readout=" + first.readout)
        shot("31-writer-apple")
        let wrote = first.readout.hasPrefix("Cleanup: Apple on-device model · Apple Foundation Models")
        let heard = first.readout.hasPrefix("Cleanup: None · raw text")
        XCTAssertTrue(wrote || heard, first.readout)
        if heard {
            XCTAssertTrue(first.readout.contains("Apple") || first.readout.contains("time limit "), "as heard with no reason: " + first.readout)
        }
        let wordsIn = first.readout.components(separatedBy: " · ").first { $0.hasSuffix(" words") }
            .flatMap { Int($0.split(separator: " ").first ?? "") } ?? 0
        let seconds = first.readout.components(separatedBy: " · ").first { $0.first?.isNumber == true && $0.contains(" s") && !$0.hasSuffix("words") }
            .flatMap { Double($0.split(separator: " ").first ?? "") } ?? 999
        let limit = min(15, 3 + Double(wordsIn) / 20)
        print(String(format: "FFW1 writing %.2f s, limit %.2f s, wrote=%d", seconds, limit, wrote ? 1 : 0))
        XCTAssertGreaterThan(wordsIn, 0, first.readout)
        XCTAssertLessThanOrEqual(seconds, limit + 1.0, "writing step ran past its limit: " + first.readout)
        if wrote && !first.readout.contains("kept as heard") {
            let words = (ProcessInfo.processInfo.environment["FF_WRITER_WORDS"] ?? "shit,sorry,fuck").split(separator: ",")
            for w in words { XCTAssertTrue(first.text.lowercased().contains(w.lowercased()), "lost \(w): \(first.text)") }
        }
        tab("Settings")
        let whereRow = app.buttons["settings.whereItRuns"].firstMatch
        XCTAssertTrue(whereRow.waitForExistence(timeout: 10), "no Where it runs row")
        whereRow.tap()
        let writer = app.staticTexts["where.writer"]
        XCTAssertTrue(writer.waitForExistence(timeout: 10), "no writer line on Where it runs")
        XCTAssertTrue(app.staticTexts["where.speechModel"].exists, "no speech model on Where it runs")
        print("FFW1 where writer=" + writer.label)
        print("FFW1 where memory=" + app.descendants(matching: .any)["where.memory"].firstMatch.label)
        XCTAssertEqual(writer.label == "Apple Intelligence, on this device", wrote, writer.label + " vs " + first.readout)
        shot("32-where-it-runs")
    }

    /// One dictation of the test clip from the Dictate tab; waits for a readout different from `previous`.
    private func dictateForReadout(previous: String?) -> (text: String, readout: String) {
        tab("Dictate")
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["finishButton"].waitForExistence(timeout: 15))
        sleep(14) // swear.wav is under 14 s
        tapFinish()
        let readout = app.staticTexts["writeReadout"], writtenBy = app.buttons["writtenBy"]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !(readout.exists && readout.label != previous) {
            if writtenBy.exists && !readout.exists { writtenBy.tap() }   // build 18: the details open from the "Written by" line
            sleep(1)
        }
        XCTAssertTrue(readout.exists && readout.label != previous, "no new cleanup readout")
        print("FFWRITTENBY " + writtenBy.label)
        return (app.staticTexts["transcriptText"].label, readout.label)
    }
}

/// End-to-end check of the model path (final build): the test clip is dictated and whatever writer runs (Apple's model
/// with guided generation, or none) must give the text itself, with no reply around it such as
/// the "Sure, here is the rewritten text:" seen on 2026-10-30. Nothing is injected: this is the model's own answer.
extension FreeFlowUITests {
    func testW2NoLeadIn() {
        launch(onboarded: true)
        tab("Dictate")
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["finishButton"].waitForExistence(timeout: 15))
        sleep(14)
        tapFinish()
        let writtenBy = app.buttons["writtenBy"]
        XCTAssertTrue(writtenBy.waitForExistence(timeout: 120), "no Written by line")
        writtenBy.tap()
        let readout = app.staticTexts["writeReadout"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "no cleanup readout")
        XCTAssertTrue(app.staticTexts["heardText"].exists, "no Heard line")
        let text = app.staticTexts["transcriptText"].label
        print("FFW2 writtenBy=" + writtenBy.label)
        print("FFW2 text=" + text)
        print("FFW2 readout=" + readout.label)
        let lower = text.lowercased()
        for leadIn in ["sure", "here is", "here's", "okay, ", "certainly"] {
            XCTAssertFalse(lower.hasPrefix(leadIn), "reply around the text: " + text)
        }
        XCTAssertFalse(lower.contains("rewritten") || lower.contains("cleaned-up") || lower.contains("transcript"), text)
    }
}

/// Build 18 (the writer must be easy to turn off and its state plain to see; Apple Intelligence,
/// optional): Settings › Writing starts with the "Clean up with Apple Intelligence" switch and its state; off puts the
/// text in as heard with no writer at all, and the screen never says "Writing" for it. The test turns it back on.
extension FreeFlowUITests {
    func testW3WriterOff() {
        launch(onboarded: true)
        tab("Settings")
        let toggle = app.switches["settings.appleWriter"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no Apple Intelligence switch in Settings")
        setSwitch(toggle, on: false)
        XCTAssertEqual(toggle.value as? String, "0", "the switch did not turn off")
        let state = app.staticTexts["settings.writerState"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Text as heard")
        shot("33-writer-off")

        tab("Dictate")
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["finishButton"].waitForExistence(timeout: 15))
        sleep(14)
        tapFinish()
        let writtenBy = app.buttons["writtenBy"]
        let writing = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Writing'")).firstMatch
        var sawWriting = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !writtenBy.exists {
            if writing.exists { sawWriting = true }
            usleep(200_000)
        }
        XCTAssertTrue(writtenBy.exists, "no Written by line")
        XCTAssertFalse(sawWriting, "the screen said Writing with the writer Off")
        print("FFW3 writtenBy=" + writtenBy.label)
        XCTAssertTrue(writtenBy.label.hasPrefix("As heard · Apple Intelligence cleanup is off"), writtenBy.label)
        writtenBy.tap()
        XCTAssertTrue(app.staticTexts["heardText"].waitForExistence(timeout: 5), "no Heard line")

        tab("Settings")
        app.buttons["settings.whereItRuns"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["where.writer"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["where.writer"].label, "Off")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let back = app.switches["settings.appleWriter"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        setSwitch(back, on: true)
        XCTAssertEqual(back.value as? String, "1", "the switch did not turn back on")
        print("FFW3 state on=" + app.staticTexts["settings.writerState"].label)
    }

    /// A SwiftUI switch in a Form: tap it, and if the row took the tap, the switch itself.
    func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let want = on ? "1" : "0"
        guard (toggle.value as? String) != want else { return }
        toggle.tap(); sleep(1)
        if (toggle.value as? String) != want { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap(); sleep(1) }
    }
}

/// App Store frames (build 18): Settings, then a real dictation landing in Notes (Messages where the
/// simulator has no Notes) through the Free Flow keyboard with a warm session. The clip is the FF_AUDIO_FILE recording;
/// the note shows whatever the app wrote from it.
/// Env FF_STORE_CLIP_SECONDS: the clip's length (default 6).
extension FreeFlowUITests {
    func testStoreShots() {
        launch(onboarded: true)
        tab("Settings")
        XCTAssertTrue(app.switches["settings.appleWriter"].firstMatch.waitForExistence(timeout: 10), "no Apple Intelligence switch")
        sleep(1); shot("store-settings")

        tab("Dictate")
        startWarmSession()
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        let sms = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        let useNotes = notes.state != .unknown
        let host = useNotes ? notes : sms
        host.launch()
        XCTAssertTrue(host.wait(for: .runningForeground, timeout: 10), "host app did not open")
        sleep(2)
        for label in ["Continue", "Not Now", "Done", "OK"] {
            let b = host.buttons[label].firstMatch
            if b.exists && b.isHittable { b.tap(); sleep(1) }
        }
        for label in useNotes ? ["New Note", "Compose", "New note"] : ["Compose", "New Message", "compose"] {
            let b = host.buttons[label].firstMatch
            if b.waitForExistence(timeout: 2) && b.isHittable { b.tap(); sleep(1); break }
        }
        let field = host.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "no text field in the host app")
        XCTAssertTrue(showFreeFlowKeyboard(in: host, tapping: field), "Free Flow keyboard did not appear")
        let before = (field.value as? String) ?? ""
        host.buttons["kb.mic"].tap()
        let finish = host.buttons["kb.finishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 15), "the keyboard is not listening")
        let clip = Double(ProcessInfo.processInfo.environment["FF_STORE_CLIP_SECONDS"] ?? "6") ?? 6
        sleep(UInt32(clip.rounded(.up)) + 1)
        finish.tap()
        var value = before
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            value = (field.value as? String) ?? ""
            if value != before && value.split(separator: " ").count >= 3 { sleep(2); break }
            sleep(1)
        }
        value = (field.value as? String) ?? ""
        print("FFSTORE host=\(useNotes ? "notes" : "messages") landed=" + value)
        XCTAssertNotEqual(value, before, "no text landed")
        shot("store-notes-landed")
    }
}
