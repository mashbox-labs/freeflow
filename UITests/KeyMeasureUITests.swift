import GameController
import UIKit
import XCTest

/// Keyboard layout checks: key frames in points (system keyboard and ours), typing through Comfort, taps in the
/// gaps between keys (0 dropped keys), VoiceOver labels, the 123 switch, and Settings -> Classic -> Comfort.
/// Screenshots go to FF_SHOTS_DIR when set (TEST_RUNNER_FF_SHOTS_DIR on the xcodebuild command line).
final class KeyMeasureUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        // FF_LOOK=light: the app's own Appearance setting (dark by default) set to Light for this run
        app.launchArguments = ["-onboarded", "YES"] + (env["FF_LOOK"] == "light" ? ["-appearance", "light"] : [])
        if let file = env["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func tab(_ name: String) {
        // The app's tab bar sits under the keyboard: hide the keyboard first, as a person would.
        let hide = el("kb.hide")
        if hide.exists && hide.isHittable { hide.tap(); _ = hide.waitForNonExistence(timeout: 5) }
        func target() -> XCUIElement? {
            // tab bar button, then (iPad sidebar, iPadOS 26) the sidebar row, which is a cell with the tab's name
            for q in [app.tabBars.buttons[name], app.buttons[name].firstMatch, app.cells[name].firstMatch,
                      app.cells.containing(.staticText, identifier: name).firstMatch] where q.exists && q.isHittable { return q }
            return nil
        }
        if target() == nil {
            // iPad mini portrait: the floating tab bar shows only the first tabs (Dictate, Models, Dictionary); the
            // sidebar lists them all.
            let side = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
            if side.exists && side.isHittable { side.tap(); sleep(1) }
        }
        if let t = target() { t.tap() } else {
            print("KEYTAB \(name) not found; buttons: \(app.buttons.allElementsBoundByIndex.prefix(40).map(\.label))")
            XCTFail("tab \(name) not found")
        }
        sleep(1)
    }

    /// Settings > Keyboard > Layout, then the layout's card (ids layout.<raw value>: comfort, l1, l2, l3, l4, classic).
    /// "Comfort" and "Current" mean the default (raw value comfort).
    private func setLayout(_ name: String) {
        let raw = ["Comfort": "comfort", "Current": "comfort", "Classic": "classic"][name] ?? name
        tab("Settings")
        let card = el("layout.\(raw)")
        if !card.exists {
            let link = el("settings.keyLayout")
            for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeUp() }
            for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeDown() }
            guard link.exists && link.isHittable else {
                // Current is the default, so tests that only need it carry on (as the old segmented picker's helper
                // did on iPad); any other layout must be found.
                print("KEYLAYOUT Settings > Keyboard > Layout row not found (wanted \(raw))")
                if raw != "comfort" { XCTFail("Settings > Keyboard > Layout row") }
                tab("Dictate"); return
            }
            link.tap(); sleep(1)
        }
        for _ in 0..<8 where !(card.exists && card.isHittable) { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 5) && card.isHittable, "layout card \(raw)")
        card.tap(); sleep(1)
        XCTAssertEqual(card.value as? String, "In use", "layout \(raw) picked")
        let back = app.navigationBars.buttons.firstMatch
        if back.exists && back.isHittable { back.tap(); sleep(1) }
        tab("Dictate")
    }

    @discardableResult private func focusTryField() -> XCUIElement {
        let field = el("tryField")
        for _ in 0..<8 where !(field.exists && field.isHittable) { app.swipeUp() }
        field.tap()
        for _ in 0..<3 where !waitKeyboardUp(5) {
            // A fresh simulator opens on the iOS keyboard: switch with its globe key, as a person would (iOS then
            // remembers Free Flow as the last keyboard).
            let globe = app.buttons["Next keyboard"].firstMatch
            if globe.exists && globe.isHittable { globe.tap(); sleep(1); continue }
            // The simulator has a hardware keyboard: after our hide key iOS minimizes the software keyboard (the
            // field keeps focus) and parks it below the screen, even after a relaunch, until the focused field is
            // tapped again (testK9*). Our keys are then in the tree but off screen, so exists() alone says nothing.
            if el("kb.mic").exists || el("kb.finishButton").exists { field.tap() }
        }
        XCTAssertTrue(keyboardUp(), "Free Flow keyboard did not come up on screen")
        sleep(1)
        return field
    }

    /// Our keyboard is up: its mic, space bar or the listening panel's finish button is on screen and hittable.
    private func keyboardUp() -> Bool {
        ["kb.mic", "key.space", "kb.finishButton"].contains { onScreen($0) && el($0).isHittable }
    }

    private func waitKeyboardUp(_ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat { if keyboardUp() { return true }; usleep(300_000) } while Date() < end
        return false
    }

    private func text(_ field: XCUIElement) -> String { (field.value as? String) ?? "" }

    private func tapAt(_ x: CGFloat, _ y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
        usleep(250_000)
    }

    private func dump(_ tag: String) {
        let screen = app.windows.firstMatch.frame
        print("KEYSCREEN \(tag) \(screen.width) \(screen.height)")
        // Our keys by id: walking every element by index failed on one element (index 119), and an app snapshot
        // leaves out the keyboard extension's elements.
        let ids = "qwertyuiopasdfghjklzxcvbnm".map { "key.\($0)" } + ["key.shift", "key.delete", "key.123", "key.globe",
                                                                     "key.space", "key.return", "kb.mic", "kb.style", "kb.hide"]
        for id in ids {
            let e = el(id)
            guard e.exists else { continue }
            let f = e.frame
            print(String(format: "KEYFRAME %@ %@ %.2f %.2f %.2f %.2f", tag, id, f.minX, f.minY, f.width, f.height))
        }
    }

    private func shot(_ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["FF_SHOTS_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    func testK0SystemKeyboard() {
        // Run on a simulator where only the iOS keyboard is enabled.
        let field = el("tryField")
        for _ in 0..<8 where !(field.exists && field.isHittable) { app.swipeUp() }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        sleep(1)
        dump("system")
    }

    func testK1ComfortTypes() {
        setLayout("Comfort")
        let field = focusTryField()
        dump("comfort")
        shot("comfort")
        el("key.x").tap()
        let base = text(field)
        for c in "hello world" { el(c == " " ? "key.space" : "key.\(c)").tap() }
        XCTAssertEqual(String(text(field).dropFirst(base.count)), "hello world")
    }

    func testK2NoDeadZones() throws {
        setLayout("Comfort")
        let field = focusTryField()
        el("key.x").tap()
        // Control: coordinate taps at key centres. If these do not type either, coordinate taps do not reach the
        // keyboard extension in this simulator and the gap taps below say nothing about the layout.
        let centres = ["key.c", "key.m", "key.a"].map { el($0).frame }
        let c0 = text(field).count
        for f in centres { tapAt(f.midX, f.midY) }
        let typed = text(field).count - c0
        print("KEYGAPS-CONTROL centres=\(centres.count) typed=\(typed)")
        try XCTSkipIf(typed == 0, "coordinate taps do not reach the keyboard extension here (0 of \(centres.count) at key centres; element taps do); gap hit areas are covered by FreeFlowKit KeyGeometry tests")
        let base = text(field).count
        let q = el("key.q").frame, a = el("key.a").frame, z = el("key.z").frame, sp = el("key.space").frame, ret = el("key.return").frame, p = el("key.p").frame
        // gaps: right of q, below a, left of a at the screen edge, between z and x, right of p at the edge,
        // below space at the bottom edge, between space and return, right of return at the edge
        let points: [(CGFloat, CGFloat)] = [(q.maxX + 1.5, q.midY), (a.midX, a.maxY + 1.5), (1.5, a.midY), (z.maxX + 1.5, z.midY),
                                            (p.maxX + 1.5, p.midY), (sp.midX, sp.maxY + 1.5), (sp.maxX + 1.5, sp.midY), (ret.maxX + 1.5, ret.midY)]
        for (x, y) in points { tapAt(x, y) }
        let added = text(field).count - base
        print("KEYGAPS taps=\(points.count) added=\(added)")
        XCTAssertEqual(added, points.count, "dropped \(points.count - added) of \(points.count) gap taps")
        // The drawn gap under m types m (Apple's hit rows favour the key above)
        let m = el("key.m").frame, del = el("key.delete").frame
        let before = text(field)
        // Inside the drawn gap: 9 pt on the iPhone; on the iPad (build 9: Apple's iPad row pitch 64.5 and key height
        // 55.5, a 9.0 pt gap) m.maxY + 9 is the top edge of the return key under m, which rightly types return
        // (gate 13 iPad Pro, 10-30).
        let below = min(9, sp.minY - m.maxY - 2)
        tapAt(m.midX, m.maxY + below)
        XCTAssertEqual(text(field), before + "m", "tap in the gap under m (\(below) pt below it)")
        // Comfort v2: return is one reverse L with no moat; the join between its upper arm and
        // its foot types return (build 5 had a dead moat under backspace here).
        let afterM = text(field)
        _ = del
        tapAt(ret.maxX - 10, ret.minY + 50)
        XCTAssertEqual(text(field), afterM + "\n", "a tap where the return's arm meets its foot")
    }

    func testK3SwitchNoJump() {
        setLayout("Comfort")
        focusTryField()
        let q = el("key.q").frame, space = el("key.space").frame, micTop = el("kb.mic").frame.minY
        el("key.123").tap(); sleep(1)
        XCTAssertEqual(el("key.1").frame, q, "123 layer moved the first key")
        XCTAssertEqual(el("key.space").frame, space, "123 layer moved space")
        el("key.123").tap(); sleep(1)
        XCTAssertEqual(el("key.q").frame, q)
        setLayout("Classic")
        focusTryField()
        dump("classic")
        shot("classic")
        let classicTop = el("kb.mic").frame.minY - 6, comfortTop = micTop - 3
        print("KEYTOP comfort=\(comfortTop) classic=\(classicTop)")
        XCTAssertEqual(classicTop, comfortTop, accuracy: 1.0, "keyboard top moved between layouts")
        setLayout("Comfort")
    }

    func testK4VoiceOverLabels() {
        setLayout("Comfort")
        focusTryField()
        var ids = "abcdefghijklmnopqrstuvwxyz".map { "key.\($0)" }
        ids += ["key.shift", "key.delete", "key.123", "key.space", "key.return", "kb.mic", "kb.style", "kb.hide"]
        var missing: [String] = []
        for id in ids {
            let e = el(id)
            if !e.exists || e.label.isEmpty || !e.isHittable { missing.append(id) }
        }
        print("KEYLABELS checked=\(ids.count) missing=\(missing)")
        XCTAssertEqual(missing, [])
        XCTAssertEqual(el("key.return").label, "return")
        XCTAssertTrue(el("kb.mic").label.hasPrefix("Dictate"))
        XCTAssertEqual(el("kb.hide").label, "Hide keyboard")
    }

    private func hideAndCheck(_ tag: String, anchor: String = "kb.mic") {
        let hide = el("kb.hide")
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "\(tag): no hide key")
        XCTAssertTrue(el(anchor).exists, "\(tag): \(anchor) not on screen before hide")
        hide.tap()
        XCTAssertTrue(el(anchor).waitForNonExistence(timeout: 8), "\(tag): keyboard still up after hide")
        XCTAssertTrue(el("kb.hide").waitForNonExistence(timeout: 3), "\(tag): hide key still on screen")
    }

    /// A hide key in both layouts (dismissKeyboard).
    func testK5HideComfort() {
        setLayout("Comfort")
        focusTryField()
        shot("comfort-hide-before")
        hideAndCheck("Comfort")
        shot("comfort-hide-after")
        focusTryField()
        XCTAssertTrue(onScreen("key.q") && el("key.q").isHittable, "keyboard comes back on screen after hide")
    }

    func testK6HideClassic() {
        setLayout("Classic")
        focusTryField()
        shot("classic-hide-before")
        hideAndCheck("Classic")
        focusTryField()
        setLayout("Comfort")
    }

    private func startSession() {
        tab("Dictate")
        let session = app.buttons["sessionButton"]
        for _ in 0..<8 where !(session.exists && session.isHittable) { app.swipeUp() }
        if session.label == "Start session" { session.tap(); sleep(2) }
    }

    private func waitForText(_ field: XCUIElement, count n: Int, word: String = "country", timeout: TimeInterval = 180) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var value = ""
        while Date() < deadline {
            value = text(field)
            if value.lowercased().components(separatedBy: word).count - 1 >= n { break }
            sleep(1)
        }
        return value
    }

    /// Dictation keeps recording after the keyboard hides, and the text lands (confirmed on a device, 2026-10-29).
    /// A: record, hide, come back while listening, finish. B: record, finish, hide at once so the result arrives
    /// while the keyboard is hidden, come back: the text lands then. Needs FF_AUDIO_FILE (the JFK clip).
    func testK7TextLandsAfterDismiss() throws {
        try XCTSkipIf(env["FF_AUDIO_FILE"] == nil, "needs FF_AUDIO_FILE")
        setLayout("Comfort")
        startSession()
        var field = focusTryField()
        el("kb.mic").tap()
        XCTAssertTrue(el("kb.finishButton").waitForExistence(timeout: 20), "listening panel")
        shot("listening-hide-key")
        hideAndCheck("listening", anchor: "kb.finishButton")
        sleep(6)                                   // still recording with the keyboard down
        field = focusTryField()
        let finish = el("kb.finishButton")
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "back on the listening panel after showing the keyboard again")
        sleep(4)
        finish.tap()
        var value = waitForText(field, count: 1)
        print("FFDISMISS-A " + value)
        XCTAssertTrue(value.lowercased().contains("country"), "A: " + value)
        XCTAssertTrue(el("key.q").waitForExistence(timeout: 10), "back to keys after the text lands")

        el("kb.mic").tap()
        XCTAssertTrue(el("kb.finishButton").waitForExistence(timeout: 20))
        sleep(10)
        el("kb.finishButton").tap()
        hideAndCheck("writing", anchor: "kb.finishButton")                    // the result arrives while the keyboard is hidden
        sleep(25)
        field = el("tryField")
        field.tap()
        value = waitForText(field, count: 2, timeout: 120)
        print("FFDISMISS-B " + value)
        XCTAssertEqual(value.lowercased().components(separatedBy: "country").count - 1, 2, "B: " + value)
    }

    /// Left-handed mirrors the top row (Dictate on the left, hide on the right).
    func testK8LeftHanded() {
        setLayout("Comfort")
        tab("Settings")
        let left = app.segmentedControls["keyHandPicker"].buttons["Left"]
        XCTAssertTrue(left.waitForExistence(timeout: 10), "Dictate key side picker")
        left.tap()
        tab("Dictate")
        focusTryField()
        let w = app.windows.firstMatch.frame.width
        let mic = el("kb.mic").frame, hide = el("kb.hide").frame
        print("KEYHAND left mic=\(mic) hide=\(hide)")
        shot("comfort-left")
        XCTAssertTrue(onScreen("kb.mic") && onScreen("kb.hide"), "Dictate and hide keys on screen")
        XCTAssertLessThan(mic.midX, w / 2, "Dictate on the left"); XCTAssertGreaterThan(hide.midX, w / 2, "hide on the right")
        tab("Settings")
        app.segmentedControls["keyHandPicker"].buttons["Right"].tap()
        tab("Dictate")
        focusTryField()
        XCTAssertTrue(onScreen("kb.mic"), "Dictate key on screen")
        XCTAssertGreaterThan(el("kb.mic").frame.midX, w / 2, "Dictate back on the right")
    }

    // MARK: Open 1: hide, switch tabs, relaunch, tap the field. One step at a time, a full-screen capture
    // after each, and where our keys really are (on screen and hittable, not just in the tree).

    private func onScreen(_ id: String) -> Bool {
        let e = el(id)
        guard e.exists else { return false }
        let f = e.frame, s = app.windows.firstMatch.frame
        return !f.isEmpty && f.minY >= s.minY - 1 && f.maxY <= s.maxY + 1 && f.minX >= s.minX - 1 && f.maxX <= s.maxX + 1
    }

    private func reproStep(_ tag: String) {
        let field = el("tryField")
        let focus = field.exists ? ((field.value(forKey: "hasKeyboardFocus") as? Bool).map { "\($0)" } ?? "?") : "no-field"
        let mic = el("kb.mic")
        let frame = mic.exists ? "\(mic.frame)" : "-"
        print("KEYREPRO \(tag) field.focus=\(focus) mic.exists=\(mic.exists) mic.frame=\(frame) mic.onScreen=\(onScreen("kb.mic")) mic.hittable=\(mic.exists && mic.isHittable) hwKeyboard=\(GCKeyboard.coalesced != nil)")
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = "repro-\(tag)"; a.lifetime = .keepAlways; add(a)
        if let dir = env["FF_SHOTS_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("repro-\(tag)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    private func tapTryField() {
        let field = el("tryField")
        for _ in 0..<8 where !(field.exists && field.isHittable) { app.swipeUp() }
        field.tap()
        sleep(3)
        // After a simulator reboot iOS may open its own keyboard: switch with its globe key, as a person would.
        let globe = app.buttons["Next keyboard"].firstMatch
        if !el("kb.mic").exists, globe.exists, globe.isHittable { globe.tap(); sleep(2) }
    }

    func testK9HideTabRelaunch() { reproHide("k9", hide: true, tabs: true) }
    func testK9bHideRelaunch() { reproHide("k9b", hide: true, tabs: false) }
    func testK9cNoHideRelaunch() { reproHide("k9c", hide: false, tabs: false) }

    private func reproHide(_ name: String, hide: Bool, tabs: Bool) {
        setLayout("Comfort")
        reproStep("\(name)-0-start")
        tapTryField()
        if !(onScreen("kb.mic") && el("kb.mic").isHittable) { reproStep("\(name)-1a-parked-at-start"); tapTryField() }
        reproStep("\(name)-1-field-tapped")
        XCTAssertTrue(onScreen("kb.mic"), "\(name): keyboard on screen before the hide")
        if hide {
            el("kb.hide").tap(); sleep(2)
            reproStep("\(name)-2-hidden")
        }
        if tabs {
            app.tabBars.buttons["Settings"].tap(); sleep(2)
            reproStep("\(name)-3-settings-tab")
            app.tabBars.buttons["Dictate"].tap(); sleep(2)
            reproStep("\(name)-4-dictate-tab")
        }
        app.terminate(); app.launch(); sleep(3)
        reproStep("\(name)-5-relaunched")
        tapTryField()
        reproStep("\(name)-6-field-tapped")
        let back = onScreen("kb.mic") && el("kb.mic").isHittable
        print("KEYREPRO-RESULT \(name) hide=\(hide) tabs=\(tabs) backOnFirstTap=\(back)")
        if !back { tapTryField(); reproStep("\(name)-7-field-tapped-again") }
        if hide && GCKeyboard.coalesced != nil {
            XCTExpectFailure("Simulator with a hardware keyboard attached: iOS minimizes the software keyboard on our hide key (the field keeps focus) and keeps it minimized across relaunches until a focused field is tapped again. Without a hardware keyboard (a phone on its own) this must pass.")
        }
        XCTAssertTrue(back, "\(name): keyboard back on screen after relaunch and one field tap")
    }

    /// Smoke: every Comfort key on screen and hittable, then a word, shift, 123, backspace and return
    /// by key taps (real touches through the keyboard's touch surface).
    func testKSmokeTyping() {
        setLayout("Comfort")
        let field = focusTryField()
        let ids = "abcdefghijklmnopqrstuvwxyz".map { "key.\($0)" } + ["key.shift", "key.delete", "key.123", "key.space", "key.return", "kb.mic", "kb.style", "kb.hide"]
        let off = ids.filter { !(onScreen($0) && el($0).isHittable) }
        print("KEYSMOKE checked=\(ids.count) offscreen=\(off)")
        XCTAssertEqual(off, [])
        reproStep("smoke-1-keys")
        XCTAssertGreaterThan(el("kb.mic").frame.width, 100, "Comfort layout showing (wide Dictate key)")
        el("key.x").tap()
        let base = text(field)
        for c in "free" { el("key.\(c)").tap() }
        el("key.space").tap()
        el("key.shift").tap()
        for c in "flow" { el("key.\(c)").tap() }
        el("key.123").tap(); sleep(1)
        reproStep("smoke-2-123")
        el("key.1").tap()
        el("key.123").tap(); sleep(1)
        el("key.z").tap(); el("key.delete").tap()
        el("key.return").tap()
        for c in "ok" { el("key.\(c)").tap() }
        let got = String(text(field).dropFirst(base.count))
        print("KEYSMOKE typed=\(got.debugDescription)")
        XCTAssertEqual(got, "free Flow1\nOk", "build 18: a new line starts a sentence, so o is a capital (as Apple's)")
        reproStep("smoke-3-typed")
    }

    /// Gate: exact text from taps at key centres and near each key's edge (82% of the way out).
    func testKGateTyping() {
        setLayout("Comfort")
        let field = focusTryField()
        reproStep("gate-1-keys")
        XCTAssertGreaterThan(el("kb.mic").frame.width, 100, "Comfort layout showing (wide Dictate key)")
        el("key.x").tap()
        let base = text(field)
        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (-0.82, 0), (0.82, 0), (0, -0.82), (0, 0.82), (0.7, 0.7), (-0.7, -0.7)]
        var n = 0
        func tapKey(_ id: String) {
            let f = el(id).frame, o = offsets[n % offsets.count]; n += 1
            tapAt(f.midX + o.0 * f.width / 2, f.midY + o.1 * f.height / 2)
        }
        func type(_ s: String) { for c in s { tapKey(c == " " ? "key.space" : "key.\(c)") } }
        type("settings the quick brown fox jumps over the lazy dog ")
        tapKey("key.shift"); type("flow")
        tapKey("key.123"); sleep(1); type("2026"); tapKey("key.123"); sleep(1)
        let got = String(text(field).dropFirst(base.count))
        print("KEYGATE taps=\(n) typed=\(got.debugDescription)")
        XCTAssertEqual(got, "settings the quick brown fox jumps over the lazy dog Flow2026")
        reproStep("gate-2-typed")
    }

    // MARK: Every layout types exactly

    /// Picks the layout in Settings, shows the keyboard in the app's field and types a fixed sentence by touching the
    /// keys (coordinate taps at the drawn keys, through the keyboard's touch surface): letters, space, shift, 123,
    /// delete, return. The text must come out exactly. L1-L3 also: a tap in the room left of delete types a space.
    private func layoutTyping(_ raw: String) {
        setLayout(raw)
        let field = focusTryField()
        reproStep("layout-\(raw)-1-keys")
        dump("layout-\(raw)")
        XCTAssertGreaterThan(el("kb.mic").frame.width, 100, "Dictate key showing")
        el("key.x").tap()
        let base = text(field)
        let offsets: [(CGFloat, CGFloat)] = [(0, 0), (-0.6, 0), (0.6, 0), (0, -0.6), (0, 0.6)]
        var n = 0
        func tapKey(_ id: String) {
            let f = el(id).frame
            if id == "key.return" {
                // the corner of the return that every layout has: its bottom-right (the foot, the tall key or Apple's)
                tapAt(f.maxX - 15, f.maxY - 15); return
            }
            let o = offsets[n % offsets.count]; n += 1
            tapAt(f.midX + o.0 * f.width / 2, f.midY + o.1 * f.height / 2)
        }
        func type(_ s: String) { for c in s { tapKey(c == " " ? "key.space" : "key.\(c)") } }
        type("settings the quick brown fox jumps over the lazy dog ")
        tapKey("key.shift"); type("flow")
        tapKey("key.123"); sleep(1); type("2026"); tapKey("key.123"); sleep(1)
        tapKey("key.delete")
        tapKey("key.return")
        type("ok")
        var want = "settings the quick brown fox jumps over the lazy dog Flow202\nOk"   // build 18: capital after a new line
        if ["l1", "l2", "l3"].contains(raw) {
            let d = el("key.delete").frame
            tapAt(d.minX - 5, d.midY)        // the room left of delete belongs to space
            want += " "
        }
        let got = String(text(field).dropFirst(base.count))
        print("KEYLAYOUT \(raw) taps=\(n) typed=\(got.debugDescription)")
        XCTAssertEqual(got, want, "layout \(raw)")
        reproStep("layout-\(raw)-2-typed")
        if raw != "comfort" { setLayout("comfort") }
    }

    func testKL0CurrentTypes() { layoutTyping("comfort") }
    func testKL1RoomyTypes() { layoutTyping("l1") }
    func testKL2BigReturnTypes() { layoutTyping("l2") }
    func testKL3TallReturnTypes() { layoutTyping("l3") }
    func testKL4DeleteAfterLTypes() { layoutTyping("l4") }
    func testKL5ClassicTypes() { layoutTyping("classic") }

    /// Settings > Keyboard > Layout: every card with its preview (screenshots), then picking a layout while the
    /// keyboard is up switches the keyboard without hiding it (L4: delete moves next to l).
    func testKLayoutPage() {
        openLayoutPage()
        reproStep("layoutpage-1-top")
        let ids = ["comfort", "l1", "l2", "l3", "l4", "classic"]
        for id in ids { XCTAssertTrue(el("layout.\(id)").exists, "card \(id)") }
        for i in 2..<6 { app.swipeUp(); sleep(1); reproStep("layoutpage-\(i)-scrolled") }
        for _ in 0..<6 { app.swipeDown() }
        // live switch: keyboard up in the page's own field, pick L4, delete moves to the a row without hiding the keyboard.
        // Build 9 gate: the keyboard was only in the element tree (parked below the screen) and L4, card 5 of 6, was
        // below the fold, never scrolled to. Now: the keyboard on screen, then the page scrolled until L4 sits above it.
        let field = el("layoutTryField")
        XCTAssertTrue(bringUpKeyboard(field), "Free Flow keyboard on screen on the layout page")
        let before = el("key.delete").frame
        let l4 = el("layout.l4")
        XCTAssertTrue(scrollPage(toShow: l4), "L4 card scrolled above the keyboard")
        reproStep("layoutpage-6-l4-above-keyboard")
        XCTAssertTrue(keyboardUp(), "keyboard still up after scrolling the page")
        if l4.isHittable { l4.tap() } else { XCTFail("L4 card hidden under the keyboard") }
        sleep(2)
        XCTAssertEqual(l4.value as? String, "In use", "L4 picked")
        XCTAssertTrue(keyboardUp(), "keyboard still up after picking L4")
        let after = el("key.delete").frame, l = el("key.l").frame
        print("KEYLIVE delete before \(before) after \(after) l \(l)")
        XCTAssertEqual(after.midY, l.midY, accuracy: 1, "delete on the a row after picking L4, keyboard still up")
        reproStep("layoutpage-7-live-l4")
        let comfort = el("layout.comfort")
        XCTAssertTrue(scrollPage(toShow: comfort), "Current card scrolled above the keyboard")
        if comfort.isHittable { comfort.tap() } else { XCTFail("Current card hidden under the keyboard") }
        sleep(1)
        XCTAssertEqual(el("key.delete").frame.midY, el("key.space").frame.midY, accuracy: 1, "back to Current: delete beside return")
    }

    // MARK: The layout previews are the keyboard as it is now

    /// Settings > Keyboard > Layout.
    private func openLayoutPage() {
        tab("Settings")
        let link = el("settings.keyLayout")
        for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeUp() }
        XCTAssertTrue(link.exists && link.isHittable, "Settings > Keyboard > Layout row")
        reproStep("layoutpage-0-settings")
        link.tap(); sleep(1)
    }

    /// Taps `field` until the Free Flow keyboard is on screen, not just in the element tree (as focusTryField): a fresh
    /// simulator opens on the iOS keyboard until its globe key switches, and with a hardware keyboard attached the
    /// simulator parks the software keyboard below the screen until the focused field is tapped again.
    private func bringUpKeyboard(_ field: XCUIElement) -> Bool {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "field \(field)")
        field.tap()
        for _ in 0..<4 where !waitKeyboardUp(5) {
            let globe = app.buttons["Next keyboard"].firstMatch
            if globe.exists && globe.isHittable { globe.tap(); sleep(1); continue }
            field.tap()
        }
        sleep(1)
        return keyboardUp()
    }

    /// The top of the Free Flow keyboard on screen: its own frame (kb.keyboard), else 3 pt above the action row.
    private func keyboardTop() -> CGFloat {
        let k = el("kb.keyboard")
        if k.exists && !k.frame.isEmpty { return k.frame.minY }
        let mic = el("kb.mic")
        return mic.exists ? mic.frame.minY - 3 : app.windows.firstMatch.frame.maxY
    }

    /// Scrolls the PAGE, never the keyboard: slow drags (held at the end, no fling) between the navigation bar and the
    /// keyboard's top, until the card shows between them. When the card is taller than that room, the part that must
    /// show is its bottom (the preview): `fromBottom` points of it, or as much as fits.
    @discardableResult private func scrollPage(toShow card: XCUIElement, fromBottom: CGFloat? = nil) -> Bool {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.windows.firstMatch.frame.width * 0.5
        for _ in 0..<12 {
            guard card.exists else { return false }
            let nav = app.navigationBars.firstMatch
            let top = (nav.exists ? nav.frame.maxY : app.windows.firstMatch.frame.minY) + 4
            let bottom = keyboardTop() - 4
            let f = card.frame
            let need = min(fromBottom ?? f.height, f.height, bottom - top)
            let lo = f.maxY - need, hi = f.maxY
            if lo >= top - 0.5 && hi <= bottom + 0.5 { return card.isHittable || fromBottom != nil }
            // content moves up by `shift` (negative: down), to centre the part that must show
            let room = bottom - top
            let shift = max(-(room - 40), min(room - 40, (lo + hi) / 2 - (top + bottom) / 2))
            let y0 = shift > 0 ? bottom - 16 : top + 16
            origin.withOffset(CGVector(dx: x, dy: y0))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: y0 - shift)),
                       withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.4)
            sleep(1)
        }
        return false
    }

    /// The previews must never show an old version of the keyboard. For every layout, on the layout page
    /// with the Free Flow keyboard up in the page's field: pick it, take one screenshot, crop the real keyboard (the
    /// union of its key elements) and the same region of the in-use card's preview, scale the real one to the preview's
    /// size and compare pixels. A restyle that reaches the keyboard and not the previews (or the reverse) fails here.
    ///
    /// Equal by setup, not by tolerance: shift (the keyboard comes up unshifted and nothing is typed; the preview is
    /// unshifted), the status dot (both read Free Flow's mic session; this test starts none, so both are hollow), the
    /// style pill and hand (both read the App Group), light or dark (run with the simulator's appearance set to the
    /// app's: dark by default, FF_LOOK=light with a light simulator), and what is behind the keyboard: iOS's keyboard
    /// backdrop and the keys are translucent, so the real keyboard shows the page under it blurred (first green run
    /// on the Air: the next card's orange Dictate key glowed through q...p). So the real keyboard is shot
    /// with the page scrolled to its end, where only the page background is behind it, and the preview in a second
    /// shot with its card scrolled into view. Behind the preview is its card (Palette.panel), behind the real keyboard
    /// the page (Palette.bg): both plain and dark, not the same colour.
    ///
    /// Where the preview is: the card draws the keyboard at the screen's width scaled to the card less 24 pt, at its
    /// bottom left 12 pt in (SettingsView KeyLayoutPage.card). The real keyboard spans the screen's width, and its
    /// outer keys sit the same distance (FreeFlowKit KeyGeometry's edge margin) from its left and top edges, so its
    /// frame follows from its key elements (kb.keyboard's own frame is only their union). Its bottom margin (Apple's
    /// bottom gap, 3 to 5 pt by device) is not visible to the test, so the preview's height is worked out with the edge
    /// margin there and its vertical position found by registration within +/- bottomSlack pt.
    ///
    /// Tolerance, and why: the preview is the keyboard drawn at scale s (< 1) and the real crop is scaled down to it,
    /// so edges land on different sub-pixel positions. Each pixel is compared with the closest of its 3 x 3 neighbours
    /// in the other image (both ways) after a 3 x 3 box blur on both, and differs when its largest channel differs by
    /// more than `pixelLimit` (of 255). A key, or the backdrop between keys, fails when more than `regionLimit` of its
    /// pixels differ. The measured green and red runs are recorded in the test output.
    func testKPreviewMatchesKeyboard() {
        openLayoutPage()
        XCTAssertTrue(bringUpKeyboard(el("layoutTryField")), "Free Flow keyboard on screen on the layout page")
        XCTAssertEqual(el("key.q").label, "q", "keyboard unshifted, like the preview")
        XCTAssertEqual(el("kb.mic").label, "Dictate, not ready", "no mic session: both status dots hollow")
        for raw in ["comfort", "l1", "l2", "l3", "l4", "classic"] {
            let card = el("layout.\(raw)")
            XCTAssertTrue(scrollPage(toShow: card), "\(raw): card above the keyboard")
            if card.isHittable { card.tap() } else { XCTFail("\(raw): card hidden under the keyboard"); continue }
            sleep(2)   // the keyboard reads the layout twice a second
            XCTAssertEqual(card.value as? String, "In use", "\(raw) picked")
            XCTAssertTrue(keyboardUp(), "\(raw): keyboard still up")
            XCTAssertTrue(scrollPageToEnd(el("layout.classic")), "\(raw): page end above the keyboard (only the page background behind it)")
            XCTAssertTrue(keyboardUp(), "\(raw): keyboard still up at the page end")
            let real = realKeyboard(), realShot = XCUIScreen.main.screenshot()
            let s = min(1, (card.frame.width - 24) / real.width)
            XCTAssertTrue(scrollPage(toShow: card, fromBottom: (real.height + Self.bottomSlack) * s + 14), "\(raw): preview above the keyboard")
            comparePreview(raw, card: card, real: real, realShot: realShot)
        }
        let comfort = el("layout.comfort")
        scrollPage(toShow: comfort)
        if comfort.isHittable { comfort.tap() }
    }

    private static let pixelLimit = 40
    private static let regionLimit = 0.02
    private static let keyIDs = "qwertyuiopasdfghjklzxcvbnm".map { "key.\($0)" }
        + ["key.shift", "key.delete", "key.123", "key.globe", "key.space", "key.return", "kb.mic", "kb.style", "kb.hide"]

    /// The bottom margin of the real keyboard the test cannot see, at most this far from the edge margin (pt).
    private static let bottomSlack: CGFloat = 4

    /// The real keyboard: its key elements and their union, and its frame worked out from them (see
    /// testKPreviewMatchesKeyboard): the screen's width, the top `inset` above the outer keys, the height with `inset`
    /// below the bottom row.
    private struct RealKeyboard {
        let keys: [(String, CGRect)]
        let union: CGRect
        let inset: CGFloat
        let width: CGFloat
        var height: CGFloat { union.height + 2 * inset }
    }

    private func realKeyboard() -> RealKeyboard {
        let keys: [(String, CGRect)] = Self.keyIDs.compactMap { id in
            let e = el(id)
            return e.exists && !e.frame.isEmpty ? (id, e.frame) : nil
        }
        let union = keys.reduce(CGRect.null) { $0.union($1.1) }
        return RealKeyboard(keys: keys, union: union, inset: union.minX, width: app.windows.firstMatch.frame.width)
    }

    /// Scrolls the page to its end with the same slow drags as scrollPage (the keyboard stays up). True when the last
    /// card ends above the keyboard's top, so only the page background is behind the keyboard.
    private func scrollPageToEnd(_ last: XCUIElement) -> Bool {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.windows.firstMatch.frame.width * 0.5
        var before = CGFloat.infinity
        for _ in 0..<12 {
            guard last.exists else { return false }
            let y = last.frame.maxY
            if abs(y - before) < 1 { break }   // the page no longer moves: at its end
            before = y
            let nav = app.navigationBars.firstMatch
            let top = (nav.exists ? nav.frame.maxY : app.windows.firstMatch.frame.minY) + 4, bottom = keyboardTop() - 4
            let y0 = bottom - 16
            origin.withOffset(CGVector(dx: x, dy: y0))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: max(top + 16, y0 - (bottom - top - 40)))),
                       withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.4)
            sleep(1)
        }
        let u = el("kb.keyboard").frame
        return last.exists && last.frame.maxY <= u.minY - u.minX
    }

    private func comparePreview(_ raw: String, card: XCUIElement, real kb: RealKeyboard, realShot: XCUIScreenshot) {
        let c = card.frame, keys = kb.keys, union = kb.union
        XCTAssertEqual(kb.width - union.maxX, kb.inset, accuracy: 1, "\(raw): keyboard spans the screen (outer keys \(kb.inset) pt in on the left, \(kb.width - union.maxX) pt on the right)")
        let s = min(1, (c.width - 24) / kb.width)
        let p0 = CGPoint(x: c.minX + 12, y: c.maxY - 12 - kb.height * s)
        let pUnion = CGRect(x: p0.x + union.minX * s, y: p0.y + kb.inset * s, width: union.width * s, height: union.height * s)
        let shot = XCUIScreen.main.screenshot()
        guard let img = shot.image.cgImage, let rimg = realShot.image.cgImage else { XCTFail("\(raw): no screenshot"); return }
        let ppp = CGFloat(img.width) / app.windows.firstMatch.frame.width
        let w = Int((pUnion.width * ppp).rounded()), h = Int((pUnion.height * ppp).rounded())
        let R = 6, RY = Int((Self.bottomSlack * s * ppp).rounded(.up)) + 2
        let real = Pixels(rimg, crop: CGRect(x: union.minX * ppp, y: union.minY * ppp, width: union.width * ppp, height: union.height * ppp).integral,
                          w: w, h: h).blurred()
        let px = Int((pUnion.minX * ppp).rounded()) - R, py = Int((pUnion.minY * ppp).rounded()) - RY
        let prev = Pixels(img, crop: CGRect(x: px, y: py, width: w + 2 * R, height: h + 2 * RY), w: w + 2 * R, h: h + 2 * RY).blurred()
        let (dx, dy) = register(real, prev, R, RY)
        let d = difference(real, prev, R + dx, RY + dy)
        // regions: each key's element frame in the crop's pixels, and the backdrop between keys
        let k = s * ppp
        var inKey = [Bool](repeating: false, count: w * h)
        var worst = (id: "", frac: 0.0), lines: [String] = []
        for (id, f) in keys {
            let x0 = max(0, Int(((f.minX - union.minX) * k).rounded()) + 1), x1 = min(w, Int(((f.maxX - union.minX) * k).rounded()) - 1)
            let y0 = max(0, Int(((f.minY - union.minY) * k).rounded()) + 1), y1 = min(h, Int(((f.maxY - union.minY) * k).rounded()) - 1)
            guard x1 > x0, y1 > y0 else { continue }
            var bad = 0
            for y in y0..<y1 { for x in x0..<x1 { inKey[y * w + x] = true; if Int(d[y * w + x]) > Self.pixelLimit { bad += 1 } } }
            let frac = Double(bad) / Double((x1 - x0) * (y1 - y0))
            lines.append(String(format: "%@=%.4f", id, frac))
            if frac > worst.frac { worst = (id, frac) }
            XCTAssertLessThanOrEqual(frac, Self.regionLimit, "\(raw): preview differs from the keyboard on \(id) (\(String(format: "%.1f", frac * 100))% of its pixels)")
        }
        var gapBad = 0, gapAll = 0, sum = 0
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<(w * h) {
            sum += Int(d[i]); hist[Int(d[i])] += 1
            if !inKey[i] { gapAll += 1; if Int(d[i]) > Self.pixelLimit { gapBad += 1 } }
        }
        let gapFrac = gapAll == 0 ? 0 : Double(gapBad) / Double(gapAll)
        XCTAssertLessThanOrEqual(gapFrac, Self.regionLimit, "\(raw): preview backdrop differs from the keyboard's (\(String(format: "%.1f", gapFrac * 100))% of pixels between keys)")
        var acc = 0, p99 = 0
        for v in 0..<256 { acc += hist[v]; if acc >= (w * h * 99) / 100 { p99 = v; break } }
        print(String(format: "PREVIEWMATCH %@ s=%.4f px=%dx%d offset=%d,%d mean=%.2f p99=%d over%d=%.4f gaps=%.4f worst=%@ %.4f",
                     raw, s, w, h, dx, dy, Double(sum) / Double(w * h), p99, Self.pixelLimit,
                     Double(hist[(Self.pixelLimit + 1)...].reduce(0, +)) / Double(w * h), gapFrac, worst.id, worst.frac))
        print("PREVIEWKEYS \(raw) " + lines.joined(separator: " "))
        XCTAssertLessThanOrEqual(abs(dx), R - 1, "\(raw): preview not where the card puts it (x offset \(dx) px)")
        XCTAssertLessThanOrEqual(abs(dy), RY - 1, "\(raw): preview not where the card puts it (y offset \(dy) px, window \(RY))")
        save("preview-\(raw)-real", real)
        save("preview-\(raw)-preview", prev.cropped(R + dx, RY + dy, w, h))
        save("preview-\(raw)-realscreen", realShot.pngRepresentation)
        save("preview-\(raw)-diff", Pixels.heat(d, w: w, h: h, limit: Self.pixelLimit))
        save("preview-\(raw)-screen", shot.pngRepresentation)
    }

    /// The offset, within ±R px across and ±RY px down of where the card puts the preview, at which the preview crop
    /// best matches the real one (sum of the largest channel difference on every 3rd pixel). Across it absorbs pixel
    /// rounding only; down also the keyboard's unseen bottom margin (bottomSlack). An offset at the edge of the search
    /// fails the test.
    private func register(_ a: Pixels, _ b: Pixels, _ R: Int, _ RY: Int) -> (Int, Int) {
        var best = (0, 0), bestScore = Int.max
        a.p.withUnsafeBufferPointer { ap in
            b.p.withUnsafeBufferPointer { bp in
                for dy in -RY...RY {
                    for dx in -R...R {
                        var score = 0
                        for y in stride(from: 0, to: a.h, by: 3) {
                            for x in stride(from: 0, to: a.w, by: 3) {
                                let i = (y * a.w + x) * 4, j = ((y + RY + dy) * b.w + (x + R + dx)) * 4
                                score += max(abs(Int(ap[i]) - Int(bp[j])), abs(Int(ap[i + 1]) - Int(bp[j + 1])), abs(Int(ap[i + 2]) - Int(bp[j + 2])))
                            }
                        }
                        if score < bestScore { bestScore = score; best = (dx, dy) }
                    }
                }
            }
        }
        return best
    }

    /// Per pixel of `a`: the largest channel difference to the closest of the 3 x 3 neighbours in `b` placed at (ox, oy),
    /// and the same the other way round; the larger of the two.
    private func difference(_ a: Pixels, _ b: Pixels, _ ox: Int, _ oy: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.w * a.h)
        a.p.withUnsafeBufferPointer { ap in
            b.p.withUnsafeBufferPointer { bp in
                func diff(_ i: Int, _ j: Int) -> Int {
                    max(abs(Int(ap[i]) - Int(bp[j])), abs(Int(ap[i + 1]) - Int(bp[j + 1])), abs(Int(ap[i + 2]) - Int(bp[j + 2])))
                }
                for y in 0..<a.h {
                    for x in 0..<a.w {
                        let i = (y * a.w + x) * 4
                        var ab = Int.max, ba = Int.max
                        let j0 = ((y + oy) * b.w + (x + ox)) * 4
                        for ny in -1...1 {
                            for nx in -1...1 {
                                let by = y + oy + ny, bx = x + ox + nx
                                if by >= 0, by < b.h, bx >= 0, bx < b.w { ab = min(ab, diff(i, (by * b.w + bx) * 4)) }
                                let ay = y + ny, ax = x + nx
                                if ay >= 0, ay < a.h, ax >= 0, ax < a.w { ba = min(ba, diff((ay * a.w + ax) * 4, j0)) }
                            }
                        }
                        out[y * a.w + x] = UInt8(min(255, max(ab, ba)))
                    }
                }
            }
        }
        return out
    }

    private func save(_ name: String, _ px: Pixels) {
        guard let png = px.png() else { return }
        save(name, png)
    }

    private func save(_ name: String, _ png: Data) {
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["FF_SHOTS_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    // MARK: Before/after shots (build 10 set). Run on build 9's app (before) and this build's (after): only element ids
    // both builds have, plus kb.keyboard where it exists. Whole-screen captures, so Apple's strip under the keyboard
    // shows on Face ID devices.

    private func screen(_ name: String) { save(name, XCUIScreen.main.screenshot().pngRepresentation) }

    /// The Dictate bar not ready and ready, Classic, and the layout page with its previews.
    func testKShotsApp() {
        setLayout("Comfort")
        focusTryField()
        print("KSHOT bar label \(el("kb.mic").label)")
        screen("shot-bar-not-ready")
        setLayout("Classic")
        focusTryField()
        screen("shot-classic")
        setLayout("Comfort")
        openLayoutPage()
        screen("shot-layout-top")
        let field = el("layoutTryField")
        if bringUpKeyboard(field) {
            for raw in ["comfort", "l4", "classic"] {
                let card = el("layout.\(raw)")
                scrollPage(toShow: card)
                screen("shot-layout-\(raw)-keyboard-up")
            }
        }
        // ready: Free Flow's mic session on
        startSession()
        focusTryField()
        let mic = el("kb.mic")
        let end = Date().addingTimeInterval(15)
        while Date() < end && !mic.label.hasSuffix(", ready") { usleep(500_000) }
        print("KSHOT bar label \(mic.label)")
        screen("shot-bar-ready")
    }

    /// The keyboard over other apps: Notes, Messages, and a dark custom page in Safari (served on the Mac's
    /// 127.0.0.1 at FF_DARK_URL). The simulator's appearance is set by the run script (dark, then light).
    /// The Free Flow keyboard up in another app: its Dictate key there, else the globe key of the keyboard showing.
    private func keyboardIn(_ host: XCUIApplication) -> Bool {
        let mic = host.buttons["kb.mic"]
        if mic.waitForExistence(timeout: 6) { return true }
        for _ in 0..<4 {
            let globe = host.buttons["Next keyboard"].firstMatch
            guard globe.exists && globe.isHittable else { break }
            globe.tap()
            if mic.waitForExistence(timeout: 4) { return true }
        }
        return mic.exists
    }

    private func tapFirst(_ host: XCUIApplication, _ labels: [String]) -> Bool {
        for l in labels {
            let b = host.buttons.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", l, l)).firstMatch
            if b.waitForExistence(timeout: 2) && b.isHittable { b.tap(); sleep(1); return true }
        }
        return false
    }

    func testKShotsHosts() {
        app.terminate()

        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.launch(); sleep(2)
        _ = tapFirst(notes, ["Continue", "Not Now", "Done"])
        _ = tapFirst(notes, ["New Note", "Compose", "New note"])   // a new note opens with its body focused
        let note = notes.textViews.firstMatch
        if !notes.buttons["kb.mic"].exists, note.waitForExistence(timeout: 4) { note.tap(); sleep(1) }
        print("KSHOT notes keyboard=\(keyboardIn(notes))")
        screen("shot-host-notes")

        let sms = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        sms.launch(); sleep(2)
        _ = tapFirst(sms, ["Continue", "Not Now", "OK"])
        _ = tapFirst(sms, ["Compose", "New Message", "compose"])
        let body = sms.textViews.firstMatch
        if body.waitForExistence(timeout: 4) { body.tap(); sleep(1) }
        print("KSHOT messages keyboard=\(keyboardIn(sms))")
        screen("shot-host-messages")

        if let page = env["FF_DARK_URL"], let url = URL(string: page) {
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            XCUIDevice.shared.system.open(url)
            _ = safari.wait(for: .runningForeground, timeout: 10); sleep(3)
            _ = tapFirst(safari, ["Continue", "Not Now"])
            let input = safari.webViews.textFields.firstMatch
            if input.waitForExistence(timeout: 8) { input.tap(); sleep(1) }
            print("KSHOT safari keyboard=\(keyboardIn(safari))")
            screen("shot-host-safari-dark-page")
        }
    }

    // MARK: The iPad's floating keyboard (for accessibility)

    /// In another app on an iPad (Notes; Messages where the simulator has none): the keyboard docked, then floating (iPadOS floats Apple's keyboard from its keyboard key's
    /// menu or a pinch; Free Flow then comes up floating through the globe key), with every key on screen inside the
    /// keyboard, one line typed exactly, and Finish reachable while listening (warm session). Lists the keyboard menu's
    /// options (Split, if iPadOS offers it). Docks the keyboard again at the end.
    func testKFloatingIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad only")
        startSession()
        print("KFLOAT session \(app.buttons["sessionButton"].label)")
        // The iPad Pro 13 simulator (iOS 26.5) has no Notes app; Messages is the host there (FF_FLOAT_HOST overrides).
        let hostID = env["FF_FLOAT_HOST"] ?? "com.apple.MobileSMS"
        print("KFLOAT host \(hostID)")
        let notes = XCUIApplication(bundleIdentifier: hostID)
        notes.launch(); sleep(2)
        _ = tapFirst(notes, ["Continue", "Not Now", "Done", "OK"])
        _ = tapFirst(notes, ["New Note", "Compose", "New note", "New Message", "compose"])
        // Messages on iPadOS 27 types into a text field (messageBodyField), Notes into a text view.
        let note = hostID == "com.apple.MobileSMS" ? notes.textFields["messageBodyField"] : notes.textViews.firstMatch
        if !notes.buttons["kb.mic"].exists, note.waitForExistence(timeout: 4) { note.tap(); sleep(1) }
        XCTAssertTrue(keyboardIn(notes), "Free Flow keyboard in \(hostID)")
        func kbFrame() -> CGRect { notes.descendants(matching: .any)["kb.keyboard"].firstMatch.frame }
        print("KFLOAT docked kb=\(kbFrame())")
        screen("floating-docked")

        // Apple's keyboard, as a person would switch: our globe key.
        let ours = notes.buttons["kb.mic"]
        for _ in 0..<4 where ours.exists {
            let g = notes.descendants(matching: .any)["key.globe"].firstMatch
            if g.exists && g.isHittable { g.tap() } else { notes.buttons["Next keyboard"].firstMatch.tap() }
            sleep(2)
        }
        let apple = notes.keyboards.firstMatch
        print("KFLOAT apple keyboard=\(apple.exists) frame=\(apple.frame)")
        // Apple's keyboard key menu: its options (Floating, Split, Dock) as iPadOS offers them here.
        let dismiss = apple.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard'")).allElementsBoundByIndex
            .last { $0.isHittable }
        var floated = false
        if let key = dismiss {
            key.press(forDuration: 1.2); sleep(1)
            let menu = notes.menuItems.allElementsBoundByIndex.map(\.label)
            let named = notes.buttons.allElementsBoundByIndex.map(\.label)
                .filter { ["Floating", "Split", "Dock", "Undock", "Merge", "Dock and Merge"].contains($0) }
            let items = menu + named
            print("KFLOAT keyboard menu: \(items)")
            screen("floating-menu")
            let floating = notes.menuItems["Floating"].exists ? notes.menuItems["Floating"] : notes.buttons["Floating"]
            if floating.exists && floating.isHittable { floating.tap(); sleep(2); floated = true }
            else { notes.tap(); sleep(1) }
        }
        if !floated {
            apple.pinch(withScale: 0.4, velocity: -1.5); sleep(2)
        }
        print("KFLOAT apple after float frame=\(notes.keyboards.firstMatch.frame)")
        screen("floating-apple")
        XCTAssertTrue(keyboardIn(notes), "Free Flow keyboard back, floating")
        sleep(1)
        let kb = kbFrame(), screenF = notes.windows.firstMatch.frame
        print("KFLOAT floating kb=\(kb) screen=\(screenF)")
        XCTAssertLessThan(kb.width, 500, "floating keyboard narrow (got \(kb.width) pt)")
        screen("floating-idle")

        // Every key on screen, hittable and inside the keyboard (no clipped keys).
        var bad: [String] = []
        let all = Self.keyIDs + ["key.shift", "key.delete", "key.123", "key.space", "key.return", "key.globe", "kb.mic", "kb.style", "kb.hide"]
        var seen = 0
        for id in all {
            let e = notes.descendants(matching: .any)[id].firstMatch
            guard e.exists else { continue }
            seen += 1
            let f = e.frame
            if !(e.isHittable && kb.insetBy(dx: -0.5, dy: -0.5).contains(f) && screenF.contains(f)) { bad.append("\(id) \(f)") }
        }
        print("KFLOAT keys checked \(seen) of \(all.count) (globe only when iPadOS asks for it); outside or not hittable: \(bad)")
        XCTAssertGreaterThanOrEqual(seen, all.count - 1, "floating: keys on screen")
        XCTAssertEqual(bad, [], "floating: keys clipped or unreachable")

        // One line, typed with the keys.
        let base = (note.value as? String) ?? ""
        for c in "floating ok" { notes.descendants(matching: .any)[c == " " ? "key.space" : "key.\(c)"].firstMatch.tap() }
        sleep(1)
        let now = (note.value as? String) ?? ""
        let typed = now.hasPrefix(base) ? String(now.dropFirst(base.count)) : now
        print("KFLOAT typed \(typed.debugDescription)")
        XCTAssertEqual(typed, "floating ok", "typed in floating mode")
        screen("floating-typed")

        // Listening: Finish reachable inside the floating keyboard.
        ours.tap()
        let finish = notes.buttons["kb.finishButton"]
        let listening = finish.waitForExistence(timeout: 15)
        print("KFLOAT listening=\(listening) finish=\(finish.exists ? "\(finish.frame)" : "-") kb=\(kbFrame())")
        screen("floating-listening")
        XCTAssertTrue(listening && finish.isHittable && kbFrame().insetBy(dx: -0.5, dy: -0.5).contains(finish.frame), "Finish reachable while floating")
        if listening { sleep(3); finish.tap(); _ = ours.waitForExistence(timeout: 120) }
        screen("floating-after-finish")

        // Dock again: Apple's keyboard, its menu's Dock, else a pinch out.
        for _ in 0..<4 where ours.exists {
            let g = notes.descendants(matching: .any)["key.globe"].firstMatch
            if g.exists && g.isHittable { g.tap() } else { notes.buttons["Next keyboard"].firstMatch.tap() }
            sleep(2)
        }
        if let key = notes.keyboards.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard'")).allElementsBoundByIndex.last(where: { $0.isHittable }) {
            key.press(forDuration: 1.2); sleep(1)
            let dock = notes.menuItems["Dock"].exists ? notes.menuItems["Dock"] : notes.buttons["Dock"]
            if dock.exists && dock.isHittable { dock.tap() } else { notes.tap(); notes.keyboards.firstMatch.pinch(withScale: 2.5, velocity: 1.5) }
            sleep(2)
        }
        _ = keyboardIn(notes)
        print("KFLOAT redocked kb=\(kbFrame())")
        screen("floating-redocked")
        XCTAssertGreaterThan(kbFrame().width, 500, "keyboard docked again at the end")
    }
}

/// RGBA pixels, top row first, sRGB.
private struct Pixels {
    let w: Int, h: Int
    var p: [UInt8]

    init(w: Int, h: Int) { self.w = w; self.h = h; p = [UInt8](repeating: 0, count: w * h * 4) }

    /// `img` cropped to `crop` (pixels) and drawn into w x h (scaled, high quality, when the sizes differ).
    init(_ img: CGImage, crop: CGRect, w: Int, h: Int) {
        self.init(w: w, h: h)
        guard let c = img.cropping(to: crop) else { return }
        p.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// 3 x 3 box blur (edges: the pixels that exist).
    func blurred() -> Pixels {
        var o = Pixels(w: w, h: h)
        p.withUnsafeBufferPointer { s in
            for y in 0..<h {
                for x in 0..<w {
                    var r = 0, g = 0, b = 0, n = 0
                    for yy in max(0, y - 1)...min(h - 1, y + 1) {
                        for xx in max(0, x - 1)...min(w - 1, x + 1) {
                            let i = (yy * w + xx) * 4; r += Int(s[i]); g += Int(s[i + 1]); b += Int(s[i + 2]); n += 1
                        }
                    }
                    let i = (y * w + x) * 4
                    o.p[i] = UInt8(r / n); o.p[i + 1] = UInt8(g / n); o.p[i + 2] = UInt8(b / n); o.p[i + 3] = 255
                }
            }
        }
        return o
    }

    func cropped(_ x0: Int, _ y0: Int, _ cw: Int, _ ch: Int) -> Pixels {
        var o = Pixels(w: cw, h: ch)
        for y in 0..<ch { for x in 0..<cw { for c in 0..<4 { o.p[(y * cw + x) * 4 + c] = p[((y + y0) * w + x + x0) * 4 + c] } } }
        return o
    }

    /// The difference map: grey = 4 x the difference, red = over the limit.
    static func heat(_ d: [UInt8], w: Int, h: Int, limit: Int) -> Pixels {
        var o = Pixels(w: w, h: h)
        for i in 0..<(w * h) {
            let v = UInt8(min(255, Int(d[i]) * 4))
            if Int(d[i]) > limit { o.p[i * 4] = 255; o.p[i * 4 + 1] = 0; o.p[i * 4 + 2] = 0 } else { o.p[i * 4] = v; o.p[i * 4 + 1] = v; o.p[i * 4 + 2] = v }
            o.p[i * 4 + 3] = 255
        }
        return o
    }

    func png() -> Data? {
        var copy = p
        return copy.withUnsafeMutableBytes { buf -> Data? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg).pngData()
        }
    }
}
