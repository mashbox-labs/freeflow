import XCTest

/// The trip back to the app you were typing in (2026-10-30).
///
/// Free Flow not running, its keyboard up in Contacts: the keyboard's mic opens Free Flow (freeflow://dictate). Build 26
/// (ColdStart): Free Flow only arms there and says Go back; it must not record in Free Flow. The keyboard
/// starts the dictation when it is back in an app and says "Listening, speak now" once capture is live. RT1 times that
/// trip as a person makes it: mic tap, Free Flow in front saying Go back, iOS's own back-to-app button (the breadcrumb)
/// or, when there is none, the swipe right along the bottom edge, Contacts in front, the keyboard live, Finish, the text
/// in the field; then a second dictation in the same session, which needs no trip. RT2 never goes back (the mic turns
/// off), RT3 taps Stay here, RT4 goes back to a different app. One `FFRT step=<name> t=<seconds since that dictation's mic tap> taps=<n>` line per
/// step; FFRTINFO / FFRTCAND lines say what was seen. Screenshots: attachments, and PNGs in FF_SHOTS_DIR when set.
///
/// The sim must already be set up (gate step test0FreshSimulatorSetup and a downloaded model). The talking is real: the
/// app's capture feeds FF_AUDIO_FILE (11 s JFK clip) through the mic path. iOS, not XCTest, starts Free Flow here, so
/// the harness sets FF_AUDIO_FILE in the simulator's launchd as well (launchctl setenv); the keyboard's listening line
/// shows "Test recording" when the clip is what is heard, and the test prints it.
final class ReturnUITests: XCTestCase {
    private var app: XCUIApplication!
    private let host = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var t0 = Date()
    private var taps = 0
    private var dictation = 1
    /// The JFK clip is 11 s. The speaker talks this long after the app says it is listening before tapping Finish.
    /// A scripted wait for the clip to play out, not a measurement: the step times around it are measured.
    private let talk: TimeInterval = 12

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        let env = ProcessInfo.processInfo.environment
        if let dir = env["FF_SHOTS_DIR"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    private func since(_ start: Date) -> String { String(format: "%.2f", Date().timeIntervalSince(start)) }

    @discardableResult
    private func step(_ name: String) -> TimeInterval {
        let t = Date().timeIntervalSince(t0)
        print(String(format: "FFRT step=%@ t=%.2f taps=%ld", name, t, taps))
        return t
    }

    /// Polls until `cond` holds. Each check is one accessibility snapshot (about 0.05 to 0.3 s), so a step time is
    /// late by at most one poll; the poll gap is printed with the step.
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            usleep(50_000)
        }
        return cond()
    }

    private func element(_ root: XCUIApplication, _ id: String) -> XCUIElement { root.descendants(matching: .any)[id].firstMatch }

    private func typeName(_ e: XCUIElement) -> String {
        switch e.elementType {
        case .button: "button"
        case .staticText: "staticText"
        case .statusBar: "statusBar"
        case .other: "other"
        case .image: "image"
        case .icon: "icon"
        case .window: "window"
        default: "type\(e.elementType.rawValue)"
        }
    }

    private func dismissKeyboardTip(_ root: XCUIApplication? = nil) {
        let host = root ?? self.host
        guard host.staticTexts["Quickly Change Keyboards"].waitForExistence(timeout: 1) else { return }
        let go = host.buttons["Continue"]
        if go.exists { go.tap(); sleep(1) }
    }

    /// The Free Flow keyboard in Contacts: tap the field, then the globe key until Free Flow's keyboard shows.
    private func showFreeFlowKeyboard(tapping field: XCUIElement, in root: XCUIApplication? = nil) -> Bool {
        let host = root ?? self.host
        field.tap()
        let mic = host.buttons["kb.mic"]
        // Build 26: a Free Flow keyboard can come up already starting or listening (a trip back), with no mic key.
        let live = host.descendants(matching: .any)["kb.listeningTitle"].firstMatch
        func ours(_ t: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(t)
            while Date() < end { if mic.exists || live.exists { return true }; usleep(100_000) }
            return mic.exists || live.exists
        }
        if ours(8) { return true }
        for _ in 0..<3 {
            dismissKeyboardTip(host)
            if ours(0.5) { return true }   // never press the globe on our own keyboard
            let globe = host.buttons["Next keyboard"].firstMatch
            guard globe.exists else { break }
            globe.tap()
            if ours(5) { return true }
            dismissKeyboardTip(host)
            if ours(2) { return true }
        }
        return mic.exists || live.exists
    }

    /// Free Flow records in front: its own Finish button (Dictate tab), or the return card's mic saying Recording.
    private func appListening() -> Bool {
        if app.buttons["finishButton"].exists { return true }
        let mic = element(app, "returnCard.mic")
        return mic.exists && (mic.value as? String) == "Recording"
    }

    /// Build 26: Free Flow armed for the trip back: the card's mic says Go back (mic on, nothing recorded).
    private func appWaitingForReturn() -> Bool {
        let mic = element(app, "returnCard.mic")
        return mic.exists && (mic.value as? String) == "Go back"
    }

    /// Every element in a status bar, and anything anywhere named like iOS's back-to-app button.
    private func breadcrumbCandidates(_ name: String, _ root: XCUIApplication) -> [XCUIElement] {
        var found: [XCUIElement] = []
        let bars = root.statusBars.allElementsBoundByIndex
        print("FFRTINFO \(name) statusBars=\(bars.count)")
        for (i, bar) in bars.enumerated() {
            for e in bar.descendants(matching: .any).allElementsBoundByIndex {
                print("FFRTCAND src=\(name) where=statusBar\(i) type=\(typeName(e)) id=[\(e.identifier)] label=[\(e.label)] frame=\(e.frame) hittable=\(e.isHittable)")
                if e.identifier.localizedCaseInsensitiveContains("breadcrumb") || e.label.localizedCaseInsensitiveContains("Contacts") { found.append(e) }
            }
        }
        let named = root.descendants(matching: .any).matching(NSPredicate(format:
            "identifier CONTAINS[c] 'breadcrumb' OR label CONTAINS[c] 'Contacts' OR label BEGINSWITH[c] 'Return to' OR label BEGINSWITH[c] 'Back to'"))
        for e in named.allElementsBoundByIndex {
            print("FFRTCAND src=\(name) where=anywhere type=\(typeName(e)) id=[\(e.identifier)] label=[\(e.label)] frame=\(e.frame) hittable=\(e.isHittable)")
            found.append(e)
        }
        return found
    }

    /// Waits for the text to land in the field: the first change from `before` (the keyboard types a dictation in one
    /// insert). Whether the words are the clip's is checked by the caller, so a short dictation still has a landing time.
    private func waitForText(_ field: XCUIElement, before: String, timeout: TimeInterval) -> String {
        var value = before
        _ = waitUntil(timeout) {
            value = (field.value as? String) ?? ""
            return value != before && !value.isEmpty && value != "Search"
        }
        return value
    }

    // MARK: The trip (build 26: Free Flow arms, the keyboard starts the dictation back in the app)

    /// Free Flow onboarded, its session off, not running; Contacts in front with the Free Flow keyboard seeing the mic off.
    private func coldStartInContacts() -> (field: XCUIElement, mic: XCUIElement) {
        let env = ProcessInfo.processInfo.environment
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES"]
        if let file = env["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        app.launch()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 20) || app.buttons["sessionButton"].waitForExistence(timeout: 5),
                      "Free Flow is not set up on this simulator (run test0FreshSimulatorSetup first)")
        let session = app.buttons["sessionButton"]
        var n = 0
        while !session.isHittable && n < 8 { app.swipeUp(); n += 1 }
        if session.exists, session.label != "Start session" { session.tap(); sleep(1) }
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Free Flow did not stop")
        host.launch()
        let field = host.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Contacts has no search field")
        XCTAssertTrue(showFreeFlowKeyboard(tapping: field), "Free Flow keyboard did not appear in Contacts")
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap(); sleep(1) }
        let mic = host.buttons["kb.mic"]
        let off = waitUntil(20) { mic.exists && mic.label.hasSuffix("not ready") }
        XCTAssertTrue(off, "the keyboard still sees a live session")
        XCTAssertEqual(app.state, .notRunning, "Free Flow must not be running before the mic tap")
        return (field, mic)
    }

    /// Mic tap -> Free Flow in front, armed, saying Go back, and NOT recording.
    private func tripToFreeFlow(_ mic: XCUIElement, tag: String) {
        t0 = Date(); taps = 0
        mic.tap(); taps += 1
        step("mic_tap")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the mic tap did not bring Free Flow to the front")
        step("ff_foreground")
        let armed = waitUntil(30) { appWaitingForReturn() }
        step("ff_armed_go_back")
        shot("\(tag)-ff-go-back")
        XCTAssertTrue(armed, "Free Flow does not show Go back (card=\(element(app, "returnCard").exists))")
        // Two seconds in Free Flow: it must stay armed, never record here.
        let recordedHere = waitUntil(2) { appListening() }
        XCTAssertFalse(recordedHere, "Free Flow started recording in Free Flow (it must wait for the trip back)")
    }

    /// iOS's back-to-app button, or the swipe right along the bottom edge when there is none.
    private func goBack() {
        let crumbs = (breadcrumbCandidates("freeflow", app) + breadcrumbCandidates("springboard", springboard)).filter { e in
            e.identifier.localizedCaseInsensitiveContains("breadcrumb")
                || (e.elementType != .icon && e.frame.minY < 70 && e.frame.height > 0 && e.label.localizedCaseInsensitiveContains("Contacts"))
        }
        let crumb = crumbs.first { $0.identifier.localizedCaseInsensitiveContains("breadcrumb") } ?? crumbs.first { $0.elementType == .button }
            ?? crumbs.first
        if let crumb {
            if crumb.isHittable { crumb.tap() } else { crumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            taps += 1
            step("breadcrumb_tap")
        } else {
            let from = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.995))
            let to = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.995))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
            taps += 1
            step("edge_swipe")
        }
    }

    /// Back in `root`: polls the keyboard until it says "Listening, speak now" (capture live). Prints when the keyboard's
    /// Starting title was seen, and the time from the app in front to live.
    private func waitLive(in root: XCUIApplication, from: Date, tag: String) -> Bool {
        let title = element(root, "kb.listeningTitle")
        var sawStarting: TimeInterval?
        let live = waitUntil(15) {
            guard title.exists else { return false }
            let l = title.label
            if sawStarting == nil, l.hasPrefix("Starting") { sawStarting = Date().timeIntervalSince(from) }
            return l.localizedCaseInsensitiveContains("speak now")
        }
        let tLive = Date().timeIntervalSince(from)
        print(String(format: "FFRT step=%@_live t=%.2f taps=%ld", tag, Date().timeIntervalSince(t0), taps))
        print(String(format: "FFRTLIVE %@ app_front_to_keyboard_live_s=%.3f starting_seen_s=%@ title=[%@]", tag, tLive,
                     sawStarting.map { String(format: "%.3f", $0) } ?? "none", title.exists ? title.label : "none"))
        return live
    }

    // MARK: The tests

    /// RT1: the trip. Free Flow arms and says Go back; back in Contacts the keyboard says Listening, speak now; the clip
    /// (the scripted speaker starts talking at that moment) lands whole. Then dictation 2, warm, in place.
    func testRT1ReturnToHost() {
        let (field, mic) = coldStartInContacts()
        shot("rt0-host-keyboard")
        var before = (field.value as? String) ?? ""
        tripToFreeFlow(mic, tag: "rt1")
        goBack()
        let back = host.wait(for: .runningForeground, timeout: 15)
        let backAt = Date()
        step("host_foreground")
        XCTAssertTrue(back, "Contacts did not come back")
        let live = waitLive(in: host, from: backAt, tag: "rt1")
        shot("rt3-back-in-host-live")
        XCTAssertTrue(live, "back in Contacts, the keyboard never said Listening, speak now")
        let finish = host.buttons["kb.finishButton"]
        XCTAssertTrue(finish.exists, "no Finish key while listening")
        usleep(UInt32(talk * 1_000_000))   // scripted: the 11 s clip plays out from the moment capture is live
        finish.tap(); taps += 1
        let tFinish = step("finish_tap")
        let text = waitForText(field, before: before, timeout: 180)
        let tText = step("text_landed")
        print(String(format: "FFRTINFO finish_to_text=%.2f s text=[%@]", tText - tFinish, text))
        shot("rt4-text-landed")
        XCTAssertTrue(text.lowercased().contains("country"), "dictation 1 text did not land: [\(text)]")
        XCTAssertTrue(text.lowercased().contains("fellow"), "the clip's first words were clipped: [\(text)]")

        // Dictation 2, same session: no trip, and the warm path is unchanged (title "Listening").
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap(); sleep(1) }
        before = (field.value as? String) ?? ""
        let warm = waitUntil(15) { mic.exists && mic.label.hasSuffix(", ready") }
        XCTAssertTrue(warm, "the session is not warm after the trip")
        dictation = 2; taps = 0
        t0 = Date()
        mic.tap(); taps += 1
        step("s2_mic_tap")
        let up2 = waitUntil(30) { finish.exists }
        let tListen2 = step("s2_listening")
        let title = element(host, "kb.listeningTitle")
        print("FFRTINFO s2 finishUp=\(up2) ff_state=\(app.state.rawValue) keyboard=[\(title.exists ? title.label : "none")]")
        XCTAssertTrue(up2, "dictation 2 did not start listening in place")
        XCTAssertNotEqual(app.state, .runningForeground, "dictation 2 brought Free Flow to the front")
        let talkLeft2 = talk - (Date().timeIntervalSince(t0) - tListen2)
        if talkLeft2 > 0 { usleep(UInt32(talkLeft2 * 1_000_000)) }
        finish.tap(); taps += 1
        let tFinish2 = step("s2_finish_tap")
        let text2 = waitForText(field, before: before, timeout: 180)
        let tText2 = step("s2_text_landed")
        print(String(format: "FFRTINFO s2 finish_to_text=%.2f s text=[%@]", tText2 - tFinish2, text2))
        XCTAssertTrue(text2.lowercased().contains("country"), "dictation 2 text did not land: [\(text2)]")
    }

    /// RT2: nobody goes back. The harness sets FF_HANDOFF_WAIT=8 in the simulator's launchd. After the wait the mic is
    /// off; opening the keyboard later starts nothing and shows the mic off.
    func testRT2NeverGoBack() {
        let wait = Double(ProcessInfo.processInfo.environment["FF_HANDOFF_WAIT"] ?? "") ?? 60
        let (_, mic) = coldStartInContacts()
        tripToFreeFlow(mic, tag: "rt2")
        XCUIDevice.shared.press(.home)
        step("home")
        sleep(UInt32(wait + 4))
        host.activate()
        step("host_again")
        let off = waitUntil(10) { mic.exists && mic.label.hasSuffix("not ready") }
        let title = element(host, "kb.listeningTitle")
        print("FFRTINFO rt2 wait=\(wait) mic=[\(mic.exists ? mic.label : "none")] listening=\(title.exists) ff_state=\(app.state.rawValue)")
        shot("rt2-after-wait")
        XCTAssertTrue(off, "the mic is still on after nobody went back")
        XCTAssertFalse(title.exists, "a dictation started after the wait ran out")
    }

    /// RT3: Stay here. The dictation starts in Free Flow at the tap; the trip's keyboard types it when it is back.
    func testRT3StayHere() {
        let (field, mic) = coldStartInContacts()
        let before = (field.value as? String) ?? ""
        tripToFreeFlow(mic, tag: "rt3")
        element(app, "returnCard.stay").tap()
        let listening = waitUntil(10) { app.buttons["finishButton"].exists }
        step("ff_listening_after_stay")
        shot("rt3-stay-listening")
        XCTAssertTrue(listening, "Stay here did not start the dictation in Free Flow")
        usleep(UInt32(talk * 1_000_000))
        app.buttons["finishButton"].tap()
        sleep(3)
        host.activate()
        let text = waitForText(field, before: before, timeout: 180)
        step("text_landed")
        print("FFRTINFO rt3 text=[\(text)]")
        XCTAssertTrue(text.lowercased().contains("country"), "Stay here dictation did not land: [\(text)]")
    }

    /// RT4: back to a different app (Safari's address field). The Free Flow keyboard that shows there starts the dictation.
    func testRT4DifferentApp() {
        let (_, mic) = coldStartInContacts()
        tripToFreeFlow(mic, tag: "rt4")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        let frontAt = Date()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Safari did not come up")
        // Safari's first-run sheet, then its address field; the keyboard there may be Apple's: switch with the globe.
        let go = safari.buttons["Continue"]
        if go.waitForExistence(timeout: 3) { go.tap(); sleep(1) }
        let address = safari.textFields.firstMatch.exists ? safari.textFields.firstMatch : safari.buttons["TabBarItemTitle"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5), "Safari shows no address field")
        if !safari.buttons["kb.finishButton"].exists {
            XCTAssertTrue(showFreeFlowKeyboard(tapping: address, in: safari) || safari.buttons["kb.finishButton"].exists,
                          "the Free Flow keyboard did not appear in Safari")
        }
        let live = waitLive(in: safari, from: frontAt, tag: "rt4")
        shot("rt4-safari-live")
        XCTAssertTrue(live, "the Free Flow keyboard in another app did not start the dictation")
        safari.buttons["kb.cancelButton"].firstMatch.tap()
    }
}

/// Build 30 checks of Settings: the Microphone picker (MicChoice) and, on a test build, the Test build
/// section, printed only: the simulator has no receipt and no AppTransaction, so a TestFlight
/// install is the only real check of that gate.
final class SettingsBuild30UITests: XCTestCase {
    func testTB1SettingsShowsTestBuildAndMicPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES"]
        app.launch()
        let bar = app.tabBars.buttons["Settings"]
        let tab = bar.exists ? bar : app.buttons["Settings"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Settings tab")
        tab.tap()
        let mic = app.descendants(matching: .any)["settings.mic"].firstMatch
        var n = 0
        while !mic.exists && n < 8 { app.swipeUp(); n += 1 }
        print("FFTB mic picker=\(mic.exists) label=[\(mic.exists ? mic.label : "")]")
        XCTAssertTrue(mic.exists, "Settings has no Microphone picker")
        let toggle = app.switches["Write keyboard dictations in the keyboard"].firstMatch
        n = 0
        while !toggle.exists && n < 14 { app.swipeUp(); n += 1 }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
        if let dir = ProcessInfo.processInfo.environment["FF_SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tb1-settings.png"))
        }
        // Not asserted: on the simulator there is no App Store receipt and no AppTransaction without a StoreKit test
        // setup, so the gate's two TestFlight signals cannot fire here. Only a TestFlight install can show it.
        print("FFTB test build section=\(toggle.exists) (simulator: informational only)")
    }
}
