import XCTest

/// The path a person really uses: the Free Flow keyboard inside ANOTHER app, the mic key opening Free Flow when no
/// session is warm, and the way back. Runs on iPad first.
/// Transcription uses FF_AUDIO_FILE like the other UI tests (the simulator's mic would record the Mac's room).
final class HostAppUITests: XCTestCase {
    let app = XCUIApplication()
    let host = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Free Flow in the background with no warm session, set up and with a test recording as its microphone.
    private func freeFlowInBackground() {
        app.launchArguments = ["-onboarded", "YES", "-sessionMinutes", "15"]
        if let file = ProcessInfo.processInfo.environment["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        app.launch()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 30), "Free Flow did not open on its home screen")
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// Contacts' search field (on every iPad and iPhone simulator), with the Free Flow keyboard up.
    private func freeFlowKeyboardInHost() -> Bool {
        host.launch()
        let search = host.searchFields.firstMatch
        guard search.waitForExistence(timeout: 15) else {
            print("FFHOST no search field: " + host.debugDescription.prefix(4000))
            return false
        }
        search.tap()
        let mic = host.buttons["kb.mic"]
        if mic.waitForExistence(timeout: 8) { return true }
        for _ in 0..<3 {
            let globe = host.buttons["Next keyboard"].firstMatch
            guard globe.exists else { break }
            globe.tap()
            if mic.waitForExistence(timeout: 5) { return true }
        }
        print("FFHOST keyboard: " + host.keyboards.debugDescription.prefix(3000))
        return mic.exists
    }

    /// Build 37: the style key shows only with Apple Intelligence cleanup on; off, the hide key is a little
    /// wider and Dictate takes the rest. FF_WRITER = apple | off (the app mirrors it to the keyboard at launch).
    /// Shots to FF_SHOTS_DIR as kb-<FF_WRITER>-<FF_SHOT_TAG>.png; key frames as KBROW lines.
    func testK1StyleKeyFollowsCleanup() {
        let env = ProcessInfo.processInfo.environment
        let writer = env["FF_WRITER"] ?? "off"
        app.launchArguments = ["-onboarded", "YES", "-writerChoice", writer]
        app.launch()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 30), "Free Flow did not open on its home screen")
        sleep(1)
        app.terminate()
        var up = freeFlowKeyboardInHost()
        // iPad: the globe can land on Emoji, whose way back is its ABC key; cycle until ours shows.
        for _ in 0..<6 where !up {
            for name in ["Next keyboard", "ABC", "abc"] {
                let b = host.buttons[name].firstMatch
                if b.exists && b.isHittable { b.tap(); break }
                let k = host.keys[name].firstMatch
                if k.exists && k.isHittable { k.tap(); break }
            }
            up = host.buttons["kb.mic"].waitForExistence(timeout: 4)
        }
        XCTAssertTrue(up, "Free Flow keyboard did not appear in Contacts")
        sleep(1)
        let style = host.descendants(matching: .any)["kb.style"].firstMatch
        let hide = host.descendants(matching: .any)["kb.hide"].firstMatch
        let mic = host.descendants(matching: .any)["kb.mic"].firstMatch
        for (id, e) in [("style", style), ("hide", hide), ("mic", mic)] where e.exists {
            print(String(format: "KBROW %@ %@ x=%.1f w=%.1f h=%.1f", writer, id, e.frame.minX, e.frame.width, e.frame.height))
        }
        XCTAssertEqual(style.exists, writer == "apple", "style key shown \(style.exists) with cleanup \(writer)")
        XCTAssertTrue(hide.exists && mic.exists)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = "kb-\(writer)"; a.lifetime = .keepAlways; add(a)
        if let dir = env["FF_SHOTS_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("kb-\(writer)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    /// The keyboard's mic key with no warm session must bring Free Flow to the front, or say on the keyboard, in
    /// words, that it could not and what to do. Never a silent wait.
    func testMicFromAnotherAppOpensFreeFlow() {
        freeFlowInBackground()
        XCTAssertTrue(freeFlowKeyboardInHost(), "Free Flow keyboard did not appear in Contacts")
        shot("40-host-keyboard")
        let tapped = Date()
        host.buttons["kb.mic"].tap()
        let opened = app.wait(for: .runningForeground, timeout: 8)
        let seconds = Date().timeIntervalSince(tapped)
        print(String(format: "FFBOUNCE opened=%@ after %.1f s, Free Flow state=%d", opened ? "yes" : "no", seconds, app.state.rawValue))
        shot(opened ? "41-freeflow-opened" : "41-open-did-not-happen")
        if !opened {
            // The keyboard must say so in words, with a way forward, well before 20 s.
            let notice = host.descendants(matching: .any)["kb.openFailed"]
            let told = notice.waitForExistence(timeout: 4)
            shot("42-keyboard-after-refused-open")
            print("FFBOUNCE keyboard told the person: \(told ? notice.label : "nothing")")
            XCTAssertTrue(told, "Free Flow did not open and the keyboard said nothing about it")
            return
        }
        // Back to the app we came from, the way a person does: the breadcrumb at the top left.
        let back = app.buttons["breadcrumb"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() } else { host.activate() }
        XCTAssertTrue(host.wait(for: .runningForeground, timeout: 8), "did not get back to Contacts")
        let finish = host.buttons["kb.finishButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 15), "keyboard is not listening after coming back")
        // Tap only once Contacts is really on screen (wait after every activate()).
        let onScreen = Date().addingTimeInterval(10)
        while Date() < onScreen && !finish.isHittable { usleep(250_000) }
        shot("43-host-listening")
        sleep(10)
        finish.tap()
        let field = host.searchFields.firstMatch
        let deadline = Date().addingTimeInterval(180)
        var value = ""
        while Date() < deadline {
            value = (field.value as? String) ?? ""
            if value.lowercased().contains("country") { break }
            sleep(1)
        }
        print("FFBOUNCE inserted: " + value)
        shot("44-host-inserted")
        XCTAssertTrue(value.lowercased().contains("country"), value)
    }

    /// Settings > General > Keyboard > Keyboards > Free Flow > Allow Full Access, set on or off like a person does.
    private func setFullAccess(_ on: Bool) -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        let back = settings.navigationBars.buttons["BackButton"].firstMatch
        var hops = 0
        while back.waitForExistence(timeout: 2) && hops < 8 { back.tap(); sleep(1); hops += 1 }
        for label in ["General", "Keyboard", "Keyboards", "Free Flow"] {
            let match = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
            let row = settings.cells.matching(match).element(boundBy: 0)
            guard row.waitForExistence(timeout: 8) else { print("FFSETTINGS missing \(label)"); return false }
            var n = 0
            while !row.isHittable && n < 10 { settings.swipeUp(); n += 1 }
            row.tap(); sleep(1)
        }
        let toggle = settings.switches["Allow Full Access"].firstMatch
        guard toggle.waitForExistence(timeout: 8) else { return false }
        if ((toggle.value as? String) == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let allow = settings.alerts.buttons["Allow"].firstMatch
            if on, allow.waitForExistence(timeout: 5) { allow.tap() }
            sleep(1)
        }
        let now = (toggle.value as? String) == "1"
        print("FFSETTINGS Allow Full Access = \(now ? "on" : "off")")
        settings.terminate()
        return now == on
    }

    /// With Allow Full Access OFF, setup must never claim it is on, however many times the keyboard opens.
    func testSetupStaysNotYetWithoutFullAccess() {
        XCTAssertTrue(setFullAccess(false), "could not turn Allow Full Access off")
        app.launchArguments = ["-onboarded", "NO", "-setup.step", "0", "-ffFreshKeyboard"]
        app.launch()
        let next = app.buttons["onboarding.next"]
        let row = app.descendants(matching: .any)["check.fullAccess"].firstMatch
        for _ in 0..<8 where !row.waitForExistence(timeout: 2) {
            guard next.waitForExistence(timeout: 10) else { break }
            next.tap()
        }
        XCTAssertTrue(row.exists, "never reached the keyboard step")
        let box = app.descendants(matching: .any)["setup.keyboardTry"].firstMatch
        var n = 0
        while !box.isHittable && n < 8 { app.swipeUp(); n += 1 }
        box.tap()
        let mic = app.buttons["kb.mic"]
        if !mic.waitForExistence(timeout: 8) {
            for _ in 0..<3 where !mic.exists {
                let globe = app.buttons["Next keyboard"].firstMatch
                guard globe.exists else { break }
                globe.tap(); _ = mic.waitForExistence(timeout: 5)
            }
        }
        XCTAssertTrue(mic.exists, "Free Flow keyboard did not appear")
        app.buttons["key.a"].firstMatch.tap()
        sleep(8)
        shot("50-setup-full-access-off")
        print("FFNOACCESS row = \(row.value as? String ?? "nil")")
        XCTAssertEqual(row.value as? String, "not yet", "setup says Full Access is on while it is off")
    }
}
