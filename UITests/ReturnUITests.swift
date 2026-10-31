import XCTest

/// The trip back to the app you were typing in (2026-10-30).
///
/// Free Flow not running, its keyboard up in Contacts: the keyboard's mic opens Free Flow (freeflow://dictate), which
/// records there. This test times that trip as a person makes it: mic tap, Free Flow in front, Free Flow listening,
/// iOS's own back-to-app button (the breadcrumb) or, when there is none, the swipe right along the bottom edge, Contacts
/// in front with the keyboard's Finish key up, Finish, the text in the field. Then a second dictation in the same
/// session, which needs no trip. One `FFRT step=<name> t=<seconds since that dictation's mic tap> taps=<n>` line per
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

    private func dismissKeyboardTip() {
        guard host.staticTexts["Quickly Change Keyboards"].waitForExistence(timeout: 1) else { return }
        let go = host.buttons["Continue"]
        if go.exists { go.tap(); sleep(1) }
    }

    /// The Free Flow keyboard in Contacts: tap the field, then the globe key until Free Flow's keyboard shows.
    private func showFreeFlowKeyboard(tapping field: XCUIElement) -> Bool {
        field.tap()
        let mic = host.buttons["kb.mic"]
        if mic.waitForExistence(timeout: 8) { return true }
        for _ in 0..<3 {
            dismissKeyboardTip()
            let globe = host.buttons["Next keyboard"].firstMatch
            guard globe.exists else { break }
            globe.tap()
            if mic.waitForExistence(timeout: 5) { return true }
            dismissKeyboardTip()
            if mic.waitForExistence(timeout: 2) { return true }
        }
        return mic.exists
    }

    /// Free Flow says it is listening: its own Finish button (Dictate tab), or the return card's mic saying Recording.
    private func appListening() -> Bool {
        if app.buttons["finishButton"].exists { return true }
        let mic = element(app, "returnCard.mic")
        return mic.exists && (mic.value as? String) == "Recording"
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

    // MARK: The test

    func testRT1ReturnToHost() {
        let env = ProcessInfo.processInfo.environment
        // Setup, not timed: Free Flow onboarded with no session on, then not running.
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
        print("FFRTINFO setup session=\(session.exists ? session.label : "?") (Start session = off)")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Free Flow did not stop")

        host.launch()
        let field = host.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Contacts has no search field")
        XCTAssertTrue(showFreeFlowKeyboard(tapping: field), "Free Flow keyboard did not appear in Contacts")
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap(); sleep(1) }
        // The keyboard must see the mic off (the app's heartbeat goes stale 3.5 s after it stops) or it would not open
        // Free Flow. Its mic key says so for VoiceOver: "Dictate, not ready" / "Dictate, ready".
        let mic = host.buttons["kb.mic"]
        let off = waitUntil(20) { mic.exists && mic.label.hasSuffix("not ready") }
        print("FFRTINFO keyboard mic=[\(mic.exists ? mic.label : "none")] off=\(off)")
        XCTAssertTrue(off, "the keyboard still sees a live session")
        XCTAssertEqual(app.state, .notRunning, "Free Flow must not be running before the mic tap")
        shot("rt0-host-keyboard")

        // Dictation 1: the trip.
        var before = (field.value as? String) ?? ""
        dictation = 1; taps = 0
        t0 = Date()
        mic.tap(); taps += 1
        step("mic_tap")
        let front = app.wait(for: .runningForeground, timeout: 30)
        step("ff_foreground")
        XCTAssertTrue(front, "the mic tap did not bring Free Flow to the front")
        let listening = waitUntil(30) { appListening() }
        let tListen = step("ff_listening")
        print("FFRTINFO ff_listening=\(listening) listeningTitle=[\(element(app, "listeningTitle").exists ? element(app, "listeningTitle").label : "none")]")
        let card = element(app, "returnCard")
        print("FFRTINFO card=\(card.exists ? "present" : "absent") label=[\(card.exists ? element(app, "returnCard.text").label : "")] backHint=\(element(app, "backHint").exists ? "present" : "absent")")
        XCTAssertTrue(listening, "Free Flow did not start listening")
        shot("rt1-ff-listening")

        // Only an element named breadcrumb, or one at the very top of the screen (status bar height) that names Contacts
        // and is not a Home Screen icon (SpringBoard keeps its icons in the tree with an app in front), counts.
        let searchStart = Date()
        let crumbs = (breadcrumbCandidates("freeflow", app) + breadcrumbCandidates("springboard", springboard)).filter { e in
            e.identifier.localizedCaseInsensitiveContains("breadcrumb")
                || (e.elementType != .icon && e.frame.minY < 70 && e.frame.height > 0 && e.label.localizedCaseInsensitiveContains("Contacts"))
        }
        let crumb = crumbs.first { $0.identifier.localizedCaseInsensitiveContains("breadcrumb") } ?? crumbs.first { $0.elementType == .button }
            ?? crumbs.first
        print("FFRTINFO breadcrumb search took \(since(searchStart)) s (test overhead inside the next step's t; a person reads the screen instead)")
        if let crumb {
            print("FFRTINFO breadcrumb=found id=[\(crumb.identifier)] label=[\(crumb.label)] frame=\(crumb.frame) hittable=\(crumb.isHittable)")
            shot("rt2-breadcrumb")
            if crumb.isHittable { crumb.tap() } else { crumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            taps += 1
            step("breadcrumb_tap")
        } else {
            print("FFRTINFO breadcrumb=none: no back-to-app button in Free Flow's or SpringBoard's status bar; swiping right along the bottom edge")
            shot("rt2-no-breadcrumb")
            let from = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.995))
            let to = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.995))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
            taps += 1
            step("edge_swipe")
        }
        let back = host.wait(for: .runningForeground, timeout: 15)
        step("host_foreground")
        let finish = host.buttons["kb.finishButton"]
        let finishUp = back && waitUntil(15) { finish.exists }
        step("host_finish_showing")
        let title = element(host, "kb.listeningTitle")
        print("FFRTINFO back=\(back) finishUp=\(finishUp) ff_state=\(app.state.rawValue) keyboard=[\(title.exists ? title.label : "none")]")
        shot("rt3-back-in-host")
        XCTAssertTrue(back, "Contacts did not come back")
        XCTAssertTrue(finishUp, "back in Contacts, the keyboard does not show Finish (not recording)")

        // Talking: the clip plays out, then Finish.
        let talkLeft = talk - Date().timeIntervalSince(t0.addingTimeInterval(tListen))
        print(String(format: "FFRTINFO talk: %.1f s more so the 11 s clip plays out (scripted wait, not measured)", max(0, talkLeft)))
        if talkLeft > 0 { usleep(UInt32(talkLeft * 1_000_000)) }
        finish.tap(); taps += 1
        let tFinish = step("finish_tap")
        let text = waitForText(field, before: before, timeout: 180)
        let tText = step("text_landed")
        print(String(format: "FFRTINFO finish_to_text=%.2f s text=[%@]", tText - tFinish, text))
        shot("rt4-text-landed")
        XCTAssertTrue(text.lowercased().contains("country"), "dictation 1 text did not land: [\(text)]")

        // Dictation 2, same session: no trip expected.
        if clear.exists { clear.tap(); sleep(1) }
        before = (field.value as? String) ?? ""
        let warm = waitUntil(15) { mic.exists && mic.label.hasSuffix(", ready") }
        print("FFRTINFO keyboard before dictation 2 mic=[\(mic.exists ? mic.label : "none")] warm=\(warm)")
        shot("rt5-host-warm")
        dictation = 2; taps = 0
        t0 = Date()
        mic.tap(); taps += 1
        step("s2_mic_tap")
        let up2 = waitUntil(30) { finish.exists }
        let tListen2 = step("s2_listening")
        print("FFRTINFO s2 finishUp=\(up2) ff_state=\(app.state.rawValue) host_state=\(host.state.rawValue) (4 = foreground) keyboard=[\(title.exists ? title.label : "none")]")
        shot("rt6-s2-listening")
        XCTAssertTrue(up2, "dictation 2 did not start listening in place")
        XCTAssertNotEqual(app.state, .runningForeground, "dictation 2 brought Free Flow to the front")
        let talkLeft2 = talk - (Date().timeIntervalSince(t0) - tListen2)
        if talkLeft2 > 0 { usleep(UInt32(talkLeft2 * 1_000_000)) }
        finish.tap(); taps += 1
        let tFinish2 = step("s2_finish_tap")
        let text2 = waitForText(field, before: before, timeout: 180)
        let tText2 = step("s2_text_landed")
        print(String(format: "FFRTINFO s2 finish_to_text=%.2f s text=[%@]", tText2 - tFinish2, text2))
        shot("rt7-s2-text-landed")
        XCTAssertTrue(text2.lowercased().contains("country"), "dictation 2 text did not land: [\(text2)]")
    }
}
