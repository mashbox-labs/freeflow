import XCTest

/// Apple's own English keyboard next to ours in the same field (Comfort v2): every key frame in
/// points (APPLEKEY / OURKEY lines in the log) and full-screen screenshots (FF_SHOTS_DIR) for the overlays.
/// On a simulator where iOS never lists the Free Flow keyboard, only Apple's half runs.
final class AppleKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES"] + (env["FF_LOOK"] == "light" ? ["-appearance", "light"] : [])
        if let file = env["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        app.launch()
        // The first launch after xcodebuild installs the app can arrive with no launch arguments (FreeFlowUITests'
        // launch), which opens setup; launch once more so -onboarded YES arrives.
        if app.buttons["onboarding.next"].waitForExistence(timeout: 3) { app.terminate(); app.launch() }
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

    /// Settings > Keyboard > Layout, then the layout's card (ids layout.<raw value>); "Comfort" is the default (comfort).
    private func setLayout(_ name: String) {
        let raw = ["Comfort": "comfort", "Current": "comfort", "Classic": "classic"][name] ?? name
        tab("Settings")
        let card = el("layout.\(raw)")
        if !card.exists {
            let link = el("settings.keyLayout")
            for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeUp() }
            for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeDown() }
            if link.exists && link.isHittable { link.tap(); sleep(1) } else { print("KEYLAYOUT layout row not found") }
        }
        for _ in 0..<8 where !(card.exists && card.isHittable) { app.swipeUp() }
        if card.exists && card.isHittable { card.tap(); sleep(1) } else { print("KEYLAYOUT card \(raw) not found") }
        let back = app.navigationBars.buttons.firstMatch
        if back.exists && back.isHittable { back.tap(); sleep(1) }
        tab("Dictate")
    }

    private func focusField() {
        let field = el("tryField")
        for _ in 0..<8 where !(field.exists && field.isHittable) { app.swipeUp() }
        field.tap(); sleep(2)
    }

    private var appleUp: Bool { app.keyboards.keys["q"].exists || app.keyboards.keys["Q"].exists }
    private var oursUp: Bool { el("key.space").exists && el("key.space").isHittable && el("key.q").exists }

    /// Apple's keyboard covers itself with a one-time "slide to type" card the first time it shows: Continue.
    private func dismissAppleCard() {
        for q in [app.buttons["Continue"], app.keyboards.buttons["Continue"], app.otherElements["Continue"]] where q.firstMatch.exists {
            q.firstMatch.tap(); sleep(1); return
        }
    }

    /// Switch keyboards with the iOS globe, as a person would, until `want` holds (at most 5 switches).
    /// The simulator has a hardware keyboard, so after a switch iOS can park the software keyboard below the screen
    /// until the focused field is tapped again (testK9*): tap the field once when ours exists off screen.
    private func switchTo(_ want: () -> Bool) -> Bool {
        for _ in 0..<5 {
            dismissAppleCard()
            if want() { return true }
            if el("key.space").exists && !el("key.space").isHittable { el("tryField").tap(); sleep(2); if want() { return true } }
            let globe = app.buttons["Next keyboard"].firstMatch
            guard globe.exists else { break }
            globe.tap(); sleep(2)
        }
        dismissAppleCard()
        return want()
    }

    private func shot(_ name: String) {
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["FF_SHOTS_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    private func line(_ prefix: String, _ tag: String, _ type: String, _ id: String, _ f: CGRect) {
        print(String(format: "%@ %@ %@ %@ %.2f %.2f %.2f %.2f", prefix, tag, type, id.replacingOccurrences(of: " ", with: "_"),
                     f.minX, f.minY, f.width, f.height))
    }

    private func dumpApple(_ tag: String) {
        line("APPLESCREEN", tag, "window", "screen", app.windows.firstMatch.frame)
        line("APPLESCREEN", tag, "keyboard", "keyboard", app.keyboards.firstMatch.frame)
        let all = app.keyboards.firstMatch.descendants(matching: .any)
        let n = all.count
        for i in 0..<n {
            let e = all.element(boundBy: i)
            guard e.exists else { continue }
            let id = e.label.isEmpty ? e.identifier : e.label
            line("APPLEKEY", tag, "\(e.elementType.rawValue)", id.isEmpty ? "?" : id, e.frame)
        }
        for id in ["Next keyboard", "Dictate", "dictation", "Emoji"] where app.buttons[id].exists {
            line("APPLEKEY", tag, "strip", id, app.buttons[id].firstMatch.frame)
        }
    }

    private func dumpOurs(_ tag: String) {
        line("OURSCREEN", tag, "window", "screen", app.windows.firstMatch.frame)
        let ids = "qwertyuiopasdfghjklzxcvbnm".map { "key.\($0)" } + ["key.shift", "key.delete", "key.123", "key.globe",
                                                                     "key.space", "key.return", "kb.mic", "kb.style", "kb.hide", "kb.cleanup"]
        for id in ids where el(id).exists { line("OURKEY", tag, "key", id, el(id).frame) }
        for id in ["Next keyboard", "Dictate"] where app.buttons[id].exists { line("OURKEY", tag, "strip", id, app.buttons[id].firstMatch.frame) }
    }

    // MARK: Build 23: the globe and every key's touch path

    /// iOS's keyboard list items: Free Flow and the other keyboards this simulator has (English, Emoji).
    private let listItem = NSPredicate(format: "label == 'Free Flow' OR label BEGINSWITH 'Free Flow,' OR label == 'Emoji' OR label BEGINSWITH 'English'")

    private func newItems(since before: Set<String>) -> [XCUIElement] {
        app.descendants(matching: .any).matching(listItem).allElementsBoundByIndex
            .filter { !before.contains(NSCoder.string(for: $0.frame)) && $0.isHittable }
    }

    private func itemFrames() -> Set<String> {
        Set(app.descendants(matching: .any).matching(listItem).allElementsBoundByIndex.map { NSCoder.string(for: $0.frame) })
    }

    /// From Apple's keyboard to ours. iPhone: a tap on Apple's globe goes to the next keyboard. iPad: Apple's globe goes
    /// to Emoji, so hold it and pick Free Flow in the list (FreeFlowUITests.switchToFreeFlow, iPad Pro 13 10-30).
    private func bringOurs() -> Bool {
        for _ in 0..<4 {
            dismissAppleCard()
            if oursUp || oursAny { return true }
            if el("key.space").exists && !el("key.space").isHittable { el("tryField").tap(); sleep(2); if oursUp { return true } }
            let globe = app.buttons.matching(NSPredicate(format: "label == 'Next keyboard'")).firstMatch
            if !(globe.exists && globe.isHittable) {
                let abc = app.buttons["ABC"].firstMatch      // iPad's Emoji keyboard has no globe, only ABC back
                if abc.exists && abc.isHittable { abc.tap(); sleep(1) }
            }
            guard globe.waitForExistence(timeout: 3) else { break }
            // Hold iOS's globe and pick Free Flow in its list (a tap goes to Emoji on iPad and cycles on iPhone).
            let before = itemFrames()
            globe.press(forDuration: 1.2); sleep(1)
            if let ff = newItems(since: before).last(where: { $0.label.hasPrefix("Free Flow") }) { ff.tap() } else { globe.tap() }
            sleep(2)
        }
        return oursUp || oursAny
    }

    private var fieldText: String { (el("tryField").value as? String) ?? "" }

    /// Ours on any page (the numbers and symbols pages have no q).
    private var oursAny: Bool { el("key.space").exists && el("key.space").isHittable && el("kb.mic").exists }

    /// A hold on `key` opens iOS's keyboard list: its items appear; picking Free Flow keeps ours.
    private func holdOpensList(_ key: XCUIElement, _ name: String) {
        let frames = itemFrames()
        key.press(forDuration: 1.5); sleep(1)
        let shown = newItems(since: frames)
        print("G1 keyboard list after a hold on \(name): \(shown.map(\.label))")
        shot("g1-list-\(name)-\(device)")
        XCTAssertFalse(shown.isEmpty, "a hold on \(name) opens iOS's keyboard list")
        if let ff = shown.last(where: { $0.label.hasPrefix("Free Flow") }) { ff.tap(); sleep(2) }
        if !oursAny { _ = bringOurs() }
        XCTAssertTrue(oursAny, "Free Flow picked in the list after \(name)")
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    /// Build 23: a hold on the page-flip key (#+= / 123, every layout) or on the globe (where iOS needs one:
    /// iPad) opens iOS's keyboard list through handleInputModeList(from:with:), Emoji one tap away; a tap on #+= still
    /// flips the page and a tap on the globe goes to the next keyboard. Every other key's touch path still works: letter
    /// taps, space, a long-press accent, delete repeat. Layout L4. Run on the iPhone and iPad simulators (FF_G1=1).
    func testG1GlobeListAndKeyPaths() throws {
        guard env["FF_G1"] == "1" else { throw XCTSkip("FF_G1 not set") }
        setLayout("l4")
        focusField()
        guard bringOurs() else { throw XCTSkip("the Free Flow keyboard is not listed on this simulator") }
        shot("g1-L4-letters-\(device)")

        // Letter taps and space.
        for c in "ok" { el("key.\(c)").tap() }
        el("key.space").tap()
        print("G1 taps+space field=\(fieldText.debugDescription)")
        XCTAssertTrue(fieldText.lowercased().hasSuffix("ok "), "letter taps and space: \(fieldText.debugDescription)")

        // Long-press accent: hold e until its panel opens, slide along, lift.
        let e = el("key.e")
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.9, thenDragTo: e.coordinate(withNormalizedOffset: CGVector(dx: 1.6, dy: -0.9)))
        let accent = fieldText.last.map(String.init) ?? ""
        print("G1 accent typed=\(accent.debugDescription)")
        XCTAssertTrue(!accent.isEmpty && "èéêëēėęěÈÉÊËĒĖĘĚ".contains(accent), "long-press accent typed \(accent.debugDescription)")

        // Delete repeat: one on touch down, then repeats while held (0.45 s, then every 0.09 s).
        for c in "abcdefghij" { el("key.\(c)").tap() }
        let before = fieldText.count
        el("key.delete").press(forDuration: 2.0)
        let removed = before - fieldText.count
        print("G1 delete held 2.0 s removed=\(removed) of \(before)")
        XCTAssertGreaterThan(removed, 5, "holding delete repeats")

        // The page-flip key: a tap flips the page, a hold opens iOS's keyboard list.
        el("key.123").tap(); sleep(1)
        let more = el("key.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3), "the numbers page has #+=")
        shot("g1-L4-numbers-\(device)")
        let numbersLabel = more.label
        let beforeTap = itemFrames()
        more.tap(); sleep(2)
        let afterTap = newItems(since: beforeTap)
        print("G1 #+= tap: ours=\(oursAny) list items=\(afterTap.map(\.label))")
        XCTAssertTrue(oursAny && afterTap.isEmpty, "a tap on #+= keeps our keyboard and opens no list")
        let symbolsLabel = el("key.more").label
        print("G1 #+= tap: \(numbersLabel) -> \(symbolsLabel)")
        XCTAssertNotEqual(numbersLabel, symbolsLabel, "a tap on #+= flips the page")
        el("key.more").tap(); sleep(1)
        XCTAssertEqual(el("key.more").label, numbersLabel, "a second tap flips back")
        holdOpensList(el("key.more"), "pageflip")
        if el("key.123").exists { el("key.123").tap(); sleep(1) }   // back to the letters

        // The globe, where iOS needs one (iPad): a hold opens the list, a tap goes to the next keyboard.
        let globe = el("key.globe")
        if device == "ipad" {
            XCTAssertTrue(globe.exists && globe.isHittable, "L4 draws a globe on iPad")
            holdOpensList(globe, "globe")
            el("key.globe").tap(); sleep(2)
            print("G1 after a tap on our globe: ours=\(oursAny) apple=\(appleUp)")
            XCTAssertFalse(oursAny, "a tap on the globe goes to the next keyboard")
            XCTAssertTrue(bringOurs(), "back to Free Flow")
        } else {
            print("G1 globe on this iPhone: \(globe.exists) (iOS draws its own below the keyboard)")
        }
    }

    /// Apple's keyboard, then Comfort, then Classic, in the same field. Leaves Free Flow as the last keyboard
    /// and Comfort as the layout.
    func testA0AppleVsOurs() {
        let hasOurs = env["FF_APPLE_ONLY"] != "1"
        if hasOurs { setLayout("Comfort") }
        focusField()
        if switchTo({ appleUp }) { dismissAppleCard(); dumpApple("apple"); shot("apple") } else { XCTFail("Apple keyboard never came up") }
        guard hasOurs else { return }
        if switchTo({ oursUp }) { dumpOurs("comfort"); shot("comfort") } else { XCTFail("Free Flow keyboard never came up") }
        setLayout("Classic"); focusField()
        if switchTo({ oursUp }) { dumpOurs("classic"); shot("classic") } else { XCTFail("Classic never came up") }
        setLayout("Comfort")
    }

    /// Apple's drawn letter centres (screen points), measured on these simulators (iOS 26.5).
    static let apple: [(name: String, w: Double, h: Double, rows: [(y: Double, xs: [Double])])] = [
        ("iPhone 17", 402, 874, [(612.5, [23.33, 62.83, 102.33, 141.83, 181.33, 220.83, 260.33, 299.83, 339.33, 378.83]), (666.5, [43.0, 82.5, 122.0, 161.5, 201.0, 240.5, 280.0, 319.5, 359.0]), (720.5, [82.5, 122.0, 161.5, 201.0, 240.5, 280.0, 319.5])]),
        ("iPhone Air", 420, 912, [(641.5, [24.17, 65.33, 106.67, 148.0, 189.33, 230.67, 272.0, 313.33, 354.67, 396.0]), (697.5, [44.67, 86.0, 127.33, 168.67, 210.0, 251.33, 292.67, 334.0, 375.33]), (753.5, [86.0, 127.33, 168.67, 210.0, 251.33, 292.67, 334.0])]),
        ("iPhone 17 Pro Max", 440, 956, [(685.5, [25.17, 68.33, 111.67, 155.0, 198.33, 241.67, 285.0, 328.33, 371.67, 415.0]), (741.5, [46.67, 90.0, 133.33, 176.67, 220.0, 263.33, 306.67, 350.0, 393.33]), (797.5, [90.0, 133.33, 176.67, 220.0, 263.33, 306.67, 350.0])]),    ]

    /// Comfort v2 on this simulator's screen: every letter within 1 pt of Apple's measured centre.
    func testA1LetterCentresMatchApple() throws {
        let screen = app.windows.firstMatch.frame.size
        let s = try XCTUnwrap(Self.apple.first { abs($0.w - screen.width) < 0.5 && abs($0.h - screen.height) < 0.5 }, "no Apple table for \(screen)")
        setLayout("Comfort"); focusField()
        XCTAssertTrue(switchTo({ oursUp }), "Free Flow keyboard up")
        var worst = 0.0
        for (r, row) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
            for (i, c) in row.enumerated() {
                let f = el("key.\(c)").frame
                let dx = abs(f.midX - s.rows[r].xs[i]), dy = abs(f.midY - s.rows[r].y)
                worst = max(worst, dx, dy)
                XCTAssertLessThanOrEqual(dx, 1, "\(c) x \(f.midX) vs Apple \(s.rows[r].xs[i])")
                XCTAssertLessThanOrEqual(dy, 1, "\(c) y \(f.midY) vs Apple \(s.rows[r].y)")
            }
        }
        print("KEYCENTRES worst \(worst) pt on \(s.name)")
        dumpOurs("v2"); shot("comfortv2")
    }

    /// The finish key in the Listening view is the Dictate key itself, same frame, with a check.
    func testA2FinishKeyIsTheDictateKey() {
        setLayout("Comfort")
        tab("Dictate")
        let session = app.buttons["sessionButton"]
        for _ in 0..<8 where !(session.exists && session.isHittable) { app.swipeUp() }
        if session.exists && session.label == "Start session" { session.tap(); sleep(2) }
        focusField()
        XCTAssertTrue(switchTo({ oursUp }), "Free Flow keyboard up")
        let dictate = el("kb.mic").frame
        el("kb.mic").tap()
        let finish = el("kb.finishButton")
        XCTAssertTrue(finish.waitForExistence(timeout: 20), "listening view")
        sleep(1)
        let f = finish.frame
        print(String(format: "FINISHFRAME %.2f %.2f %.2f %.2f dictate %.2f %.2f %.2f %.2f", f.minX, f.minY, f.width, f.height,
                     dictate.minX, dictate.minY, dictate.width, dictate.height))
        XCTAssertEqual(f.minX, dictate.minX, accuracy: 0.5); XCTAssertEqual(f.minY, dictate.minY, accuracy: 0.5)
        XCTAssertEqual(f.width, dictate.width, accuracy: 0.5); XCTAssertEqual(f.height, dictate.height, accuracy: 0.5)
        shot("listening-check")
        if el("kb.cancelButton").exists { el("kb.cancelButton").tap(); sleep(1) }
    }

    // MARK: autocorrect bench (build 12)

    /// Types every line of $FF_AC_FILE (one sentence per line, exactly as written) into the try field with one keyboard,
    /// a return after each, and writes what landed in the field, one line per sentence, to $FF_AC_OUT.
    /// FF_AC_KEYBOARD = apple (Apple's English keyboard; XCUITest typeText) or ours (Free Flow; every key tapped).
    /// Nothing is scored here: b12ac/scripts/ac12_score.py compares the output with the intended sentences.
    func testB0AutocorrectBench() throws {
        guard let path = env["FF_AC_FILE"], let out = env["FF_AC_OUT"] else { throw XCTSkip("FF_AC_FILE / FF_AC_OUT not set") }
        let ours = env["FF_AC_KEYBOARD"] == "ours"
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
        if ours { setLayout("Comfort") }
        focusField()
        XCTAssertTrue(switchTo(ours ? { self.oursUp } : { self.appleUp }), "keyboard up")
        dismissAppleCard()
        let field = el("tryField")
        let placeholder = field.placeholderValue ?? ""
        func value() -> String { let v = (field.value as? String) ?? ""; return v == placeholder ? "" : v }
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        defer { try? handle.close() }
        let t0 = Date()
        for (i, s) in lines.enumerated() {
            let before = value()
            if ours { tapOurs(s + "\n") } else { tapApple(s + "\n") }
            let after = value()
            let common = zip(before, after).prefix { $0 == $1 }.count
            if common < before.count { print("ACBENCH \(i) earlier text changed (common \(common) of \(before.count))") }
            let landed = String(after.dropFirst(common)).replacingOccurrences(of: "\n", with: "\\n")
            handle.write(Data((landed + "\n").utf8))
            if i % 20 == 0 { print(String(format: "ACBENCH %d/%d %.0f s: %@", i, lines.count, Date().timeIntervalSince(t0), landed)) }
        }
        print(String(format: "ACBENCH done %d lines in %.0f s keyboard=%@", lines.count, Date().timeIntervalSince(t0), ours ? "ours" : "apple"))
        shot("acbench-\(ours ? "ours" : "apple")")
    }

    /// Apple's keys, one tap each (typeText skips Apple's autocorrect: measured, 'teh' stayed 'teh'). Every tap lands
    /// on the key's centre, read once from the keyboard (shift renames a key, it does not move it); , . ? from the
    /// numbers plane, found by name.
    private var appleFrames: [String: CGRect] = [:]
    private func tapApple(_ text: String) {
        let kb = app.keyboards.firstMatch
        func find(_ names: [String]) -> XCUIElement? {
            for n in names { for q in [kb.keys[n], kb.buttons[n]] where q.exists { return q } }
            return nil
        }
        if appleFrames.isEmpty {
            for c in "abcdefghijklmnopqrstuvwxyz" {
                if let k = find([String(c), String(c).uppercased()]) { appleFrames[String(c)] = k.frame }
            }
            for (name, names) in [("space", ["space"]), ("return", ["return", "Return"]), ("more", ["more", "numbers", "123", "more, numbers"])] {
                if let k = find(names) { appleFrames[name] = k.frame }
            }
            print("ACBENCH apple keys \(appleFrames.count): \(appleFrames.keys.sorted().joined(separator: ","))")
        }
        func tap(_ name: String) {
            guard let f = appleFrames[name] else { print("ACBENCH no Apple key \(name)"); return }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        }
        for c in text {
            switch c {
            case " ": tap("space")
            case "\n":
                tap("return")
                if find(["q", "Q"]) == nil { find(["more", "letters", "ABC", "more, letters"])?.tap() }
            case ",", ".", "?", "!":
                tap("more")
                if let k = find([String(c)]) { k.tap() } else { print("ACBENCH no Apple key \(c)") }
            default: tap(String(c))
            }
        }
    }

    /// Free Flow's keys, one tap each at the key's centre (frames read once); , . ? from the 123 plane, back to letters.
    private var ourFrames: [String: CGRect] = [:]
    private func tapOurs(_ text: String) {
        if ourFrames.isEmpty {
            for id in "abcdefghijklmnopqrstuvwxyz".map({ "key.\($0)" }) + ["key.space", "key.return", "key.123"] where el(id).exists {
                ourFrames[id] = el(id).frame
            }
            print("ACBENCH our keys \(ourFrames.count)")
        }
        func tap(_ id: String) {
            guard let f = ourFrames[id] else { print("ACBENCH no key \(id)"); return }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        }
        for c in text {
            switch c {
            case " ": tap("key.space")
            case "\n": tap("key.return")
            case ",", ".", "?", "!":
                tap("key.123")
                el("key.\(c)").tap()
                if !el("key.q").exists { tap("key.123") }
            default: tap("key.\(c)")
            }
        }
    }
}
