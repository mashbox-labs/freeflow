import XCTest

/// Build 18 (2026-10-30): our Classic keyboard next to Apple's in the same field of other apps, page by
/// page, in the mode the simulator is in (the gate runs it in dark, then light). Shots go to FF_SHOTS_DIR as
/// m-<host>-<ours|apple>-<page>-<FF_SHOT_TAG>.png with every key frame in the log (MKEY lines), for the side-by-sides
/// and the colour numbers (our keyboard body against Apple's strip and Apple's keyboard). Also: taps in the gaps
/// between our keys must still type (the near-invisible touch floor), and long presses on ours and on Apple's
/// (hold-* screenshots from the gate's watcher; MHOLDTYPED = what a release with no movement typed).
/// Hosts: Notes (Contacts' search field where the simulator has no Notes; the iOS 27.2 simulator has none), Messages, and a Safari
/// page (FF_MATCH_URL) with one field per kind (text, email, url, number, decimal, phone, search, send).
/// FF_NO_NOTES=1: the simulator has no Notes app (the gate reads simctl listapps).
final class KeyboardMatchUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let app = XCUIApplication()

    override func setUp() { continueAfterFailure = true }

    private func shot(_ name: String) {
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["FF_SHOTS_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(env["FF_SHOT_TAG"] ?? "run").png"))
        }
    }

    private func line(_ tag: String, _ id: String, _ f: CGRect) {
        print(String(format: "MKEY %@ %@ %.2f %.2f %.2f %.2f", tag, id.replacingOccurrences(of: " ", with: "_"), f.minX, f.minY, f.width, f.height))
    }

    /// Taps the first of these buttons that shows, at the frame read once (a card that goes away on its own between
    /// the check and the tap must not fail the test).
    private func tapFirst(_ host: XCUIApplication, _ labels: [String]) -> Bool {
        for l in labels {
            let b = host.buttons.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", l, l)).firstMatch
            guard b.waitForExistence(timeout: 2) else { continue }
            let f = b.frame
            guard f.width > 0, b.isHittable else { continue }
            host.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap(); sleep(1)
            return true
        }
        return false
    }

    /// Ours: the Dictate key on screen. Apple's: a keyboard with letter or digit keys and no Dictate key on screen.
    private func ours(_ host: XCUIApplication) -> Bool {
        let mic = host.descendants(matching: .any)["kb.mic"].firstMatch
        return mic.exists && mic.isHittable
    }
    private func apple(_ host: XCUIApplication) -> Bool {
        let k = host.keyboards.firstMatch
        return !ours(host) && k.exists && (k.keys["q"].exists || k.keys["Q"].exists || k.keys["1"].exists)
    }

    /// The globe in the strip under the keyboard, until `want` holds (Apple's one-time "slide to type" card dismissed).
    private func switchTo(_ host: XCUIApplication, _ want: (XCUIApplication) -> Bool) -> Bool {
        for _ in 0..<5 {
            _ = tapFirst(host, ["Continue"])
            if want(host) { return true }
            let globe = host.buttons["Next keyboard"].firstMatch
            guard globe.exists else { break }
            globe.tap(); sleep(2)
        }
        _ = tapFirst(host, ["Continue"])
        return want(host)
    }

    private func el(_ host: XCUIApplication, _ id: String) -> XCUIElement { host.descendants(matching: .any)[id].firstMatch }

    private func dumpOurs(_ host: XCUIApplication, _ tag: String) {
        line(tag, "window", host.windows.firstMatch.frame)
        let ids = "qwertyuiopasdfghjklzxcvbnm1234567890".map { "key.\($0)" }
            + ["key.shift", "key.more", "key.delete", "key.123", "key.space", "key.return", "kb.mic", "kb.style", "kb.hide",
               "key.bx:@", "key.bx:.", "key.bx:/", "key.bx:.com", "key.padmore", "key.blank"]
        for id in ids where el(host, id).exists { line(tag, id, el(host, id).frame) }
        for id in ["Next keyboard", "Dictate", "dictation"] where host.buttons[id].exists { line(tag, "strip." + id, host.buttons[id].firstMatch.frame) }
    }

    private func dumpApple(_ host: XCUIApplication, _ tag: String) {
        line(tag, "window", host.windows.firstMatch.frame)
        let kb = host.keyboards.firstMatch
        line(tag, "keyboard", kb.frame)
        let all = kb.descendants(matching: .any)
        for i in 0..<min(all.count, 80) {
            let e = all.element(boundBy: i)
            guard e.exists, e.elementType == .key || e.elementType == .button else { continue }
            line(tag, e.label.isEmpty ? e.identifier : e.label, e.frame)
        }
        for id in ["Next keyboard", "Dictate", "dictation", "Emoji"] where host.buttons[id].exists { line(tag, "strip." + id, host.buttons[id].firstMatch.frame) }
    }

    /// The field's text (an empty web field reports its placeholder as its value).
    private func value(_ field: XCUIElement) -> String {
        let v = (field.value as? String) ?? ""
        return v == (field.placeholderValue ?? "\u{0}") ? "" : v
    }

    /// Taps in the gaps between our keys (between q and w, between the q and a rows, left of a) must each type one
    /// character: iOS must deliver touches there.
    private func gapTaps(_ host: XCUIApplication, _ field: XCUIElement, _ tag: String) {
        let q = el(host, "key.q").frame, w = el(host, "key.w").frame, a = el(host, "key.a").frame
        guard q.width > 0, w.width > 0, a.width > 0 else { print("MGAP \(tag) no keys"); return }
        let origin = host.coordinate(withNormalizedOffset: .zero)
        let points = [CGPoint(x: (q.maxX + w.minX) / 2, y: q.midY), CGPoint(x: a.midX, y: (q.maxY + a.minY) / 2),
                      CGPoint(x: a.minX / 2, y: a.midY)]
        let before = value(field).count
        for p in points { origin.withOffset(CGVector(dx: p.x, dy: p.y)).tap(); usleep(400_000) }
        sleep(1)
        let after = value(field).count
        print("MGAP \(tag) typed \(after - before) of \(points.count) (before \(before) after \(after))")
        XCTAssertEqual(after - before, points.count, "\(tag): taps between keys did not all type")
    }

    /// Every letter: which keys have a panel on Apple's keyboard is itself checked.
    static let holdLetters = "qwertyuiopasdfghjklzxcvbnm".map(String.init)
    static let holdSymbols = ["0", "-", "/", "$", "&", "\"", ".", "?", "!", "'"]

    /// A long press. A mark file in FF_SHOTS_DIR first: the gate's watcher (match/holdcap.py) takes a simulator
    /// screenshot 0.9 s later, while the variants are up. MHOLDTYPED = what the release typed (no finger movement).
    private func hold(_ who: String, _ key: XCUIElement, _ k: String, _ field: XCUIElement) {
        guard key.exists else { print("MHOLD \(who) \(k) no key"); return }
        let safe = k.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : String(format: "u%04X", $0.value) }.joined()
        if let dir = env["FF_SHOTS_DIR"] {
            FileManager.default.createFile(atPath: dir + "/hold-\(who)-\(safe).mark", contents: Data())
        }
        let before = value(field)
        print("MHOLD \(who) \(safe) \(ISO8601DateFormatter().string(from: Date()))")
        key.press(forDuration: 1.6)
        usleep(500_000)
        let after = value(field)
        print("MHOLDTYPED \(who) \(safe) [\(after.hasPrefix(before) ? String(after.dropFirst(before.count)) : after)]")
    }

    /// Our pages (letters, 123, #+=), then Apple's, in this field. Leaves Free Flow's keyboard up on its letters page.
    private func pages(_ host: XCUIApplication, _ name: String, field: XCUIElement, gaps: Bool, holds: Bool) {
        if switchTo(host, ours) {
            dumpOurs(host, "\(name)-ours-abc"); shot("m-\(name)-ours-abc")
            if gaps { gapTaps(host, field, name) }
            if holds { for k in Self.holdLetters { hold("ours", el(host, "key.\(k)"), k, field) } }
            if el(host, "key.123").exists {
                el(host, "key.123").tap(); sleep(1); dumpOurs(host, "\(name)-ours-123"); shot("m-\(name)-ours-123")
                if holds { for k in Self.holdSymbols { hold("ours", el(host, "key.\(k)"), k, field) } }
                if el(host, "key.more").exists { el(host, "key.more").tap(); sleep(1); dumpOurs(host, "\(name)-ours-sym"); shot("m-\(name)-ours-sym") }
                el(host, "key.123").tap(); sleep(1)
            }
        } else { XCTFail("\(name): Free Flow keyboard never came up") }
        if switchTo(host, apple) {
            let kb = host.keyboards.firstMatch
            dumpApple(host, "\(name)-apple-abc"); shot("m-\(name)-apple-abc")
            if holds { for k in Self.holdLetters { hold("apple", kb.keys[k], k, field) } }
            func key(_ names: [String]) -> XCUIElement? {
                for n in names {
                    for q in [kb.keys[n], kb.buttons[n]] where q.exists && q.isHittable { return q }
                }
                return nil
            }
            if let more = key(["more", "numbers", "123"]) {
                more.tap(); sleep(1); dumpApple(host, "\(name)-apple-123"); shot("m-\(name)-apple-123")
                if holds {
                    for k in Self.holdSymbols { hold("apple", key([k, k == "&" ? "ampersand" : k]) ?? kb.keys[k], k, field) }
                }
                // the page keys' identifier is "more" on every page; their labels say where they go
                if let sym = key(["symbols", "#+="]) { sym.tap(); sleep(1); dumpApple(host, "\(name)-apple-sym"); shot("m-\(name)-apple-sym") }
                if let abc = key(["letters", "ABC", "more"]) { abc.tap(); sleep(1) }
            } else { print("MAPPLE \(name) no 123 key") }
            _ = switchTo(host, ours)
        } else { XCTFail("\(name): Apple's keyboard never came up") }
    }

    func testM0HostsAppleVsOurs() {
        if env["FF_NO_NOTES"] != "1" {
            let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
            notes.launch(); sleep(2)
            _ = tapFirst(notes, ["Continue", "Not Now", "Done"])
            _ = tapFirst(notes, ["New Note", "Compose", "New note"])
            let body = notes.textViews.firstMatch
            if body.waitForExistence(timeout: 5) { body.tap(); sleep(1) }
            pages(notes, "notes", field: body, gaps: true, holds: false)
        } else {
            // No Notes on this simulator: Contacts' search field (the field HostAppUITests uses).
            print("MHOST no Notes on this simulator: Contacts instead")
            let contacts = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
            contacts.launch(); sleep(2)
            _ = tapFirst(contacts, ["Continue", "Not Now", "OK"])
            let search = contacts.searchFields.firstMatch
            if search.waitForExistence(timeout: 10) { search.tap(); sleep(1) }
            // text left from an earlier run makes Contacts search on every key and never go idle
            let clear = search.buttons.firstMatch
            if clear.exists && clear.isHittable { clear.tap(); sleep(1) }
            pages(contacts, "contacts", field: search, gaps: true, holds: false)
        }

        // Messages: a new message to a number (sms: link), the cursor in the message field.
        let sms = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        XCUIDevice.shared.system.open(URL(string: "sms:5550100")!)
        _ = sms.wait(for: .runningForeground, timeout: 10); sleep(3)
        _ = tapFirst(sms, ["Continue", "Not Now", "OK"])
        let body = sms.textViews.firstMatch.exists ? sms.textViews.firstMatch : sms.textFields.matching(NSPredicate(format: "label CONTAINS[c] 'message'")).firstMatch
        if body.waitForExistence(timeout: 5) { body.tap(); sleep(1) } else { print("MHOST messages: no message field: " + sms.debugDescription.prefix(3000)) }
        pages(sms, "messages", field: body, gaps: true, holds: false)

        guard let page = env["FF_MATCH_URL"], let url = URL(string: page) else { print("MHOST no FF_MATCH_URL"); return }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCUIDevice.shared.system.open(url)
        _ = safari.wait(for: .runningForeground, timeout: 10); sleep(3)
        _ = tapFirst(safari, ["Continue", "Not Now", "Close"])
        let text = safari.webViews.textFields["text"].firstMatch
        if text.waitForExistence(timeout: 10) { text.tap(); sleep(1) }
        // the long presses run here: a fresh web field each run, and the page goes idle at once
        pages(safari, "safari", field: text, gaps: true, holds: true)
    }

    /// One field per kind on the Safari page: ours, then Apple's, in each.
    func testM1FieldKinds() {
        guard let page = env["FF_MATCH_URL"], let url = URL(string: page) else { XCTFail("no FF_MATCH_URL"); return }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCUIDevice.shared.system.open(url)
        _ = safari.wait(for: .runningForeground, timeout: 10); sleep(3)
        _ = tapFirst(safari, ["Continue", "Not Now", "Close"])
        // Phone fields always get Apple's pad: iOS swaps a custom keyboard out for phone pads (and secure fields).
        for id in ["email", "url", "number", "decimal", "phone", "search", "send"] {
            let field = id == "search" ? safari.webViews.searchFields.firstMatch : safari.webViews.textFields[id].firstMatch
            guard field.waitForExistence(timeout: 8) else { print("MFIELD \(id) not found"); continue }
            field.tap(); sleep(2)
            let oursUp = switchTo(safari, ours)
            print("MFIELD \(id) ours=\(oursUp)")
            if oursUp {
                // The layout must follow the field with our keyboard kept up from the field before.
                let want = ["email": "key.bx:@", "url": "key.bx:.com", "number": "key.0", "decimal": "key..", "search": "key.space", "send": "key.space"][id] ?? "key.space"
                let pad = id == "number" || id == "decimal"
                let ok = el(safari, want).exists && el(safari, "key.q").exists != pad
                print("MFIELDOK \(id) \(ok)")
                XCTAssertTrue(ok, "\(id): our keyboard did not follow the field")
                dumpOurs(safari, "field-\(id)-ours"); shot("m-field-\(id)-ours")
            }
            if switchTo(safari, apple) { dumpApple(safari, "field-\(id)-apple"); shot("m-field-\(id)-apple") }
            _ = switchTo(safari, ours)
        }
        // Safari's own address bar (web search: the return key says go)
        let address = safari.textFields.matching(NSPredicate(format: "identifier == 'TabBarItemTitle' OR label CONTAINS[c] 'Address' OR identifier == 'URL'")).firstMatch
        if address.exists && address.isHittable {
            address.tap(); sleep(2)
            if switchTo(safari, ours) { dumpOurs(safari, "field-address-ours"); shot("m-field-address-ours") }
            if switchTo(safari, apple) { dumpApple(safari, "field-address-apple"); shot("m-field-address-apple") }
            _ = switchTo(safari, ours)
        } else { print("MFIELD address bar not found") }
    }

    /// Native fields (Contacts' new contact card): from the name field to an email field, then a URL field, with our
    /// keyboard kept up. Tells whether the layout follows a field change in a native app as it must in M1's web page.
    func testM2NativeFieldKinds() {
        let contacts = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
        contacts.launch(); sleep(3)
        _ = tapFirst(contacts, ["Continue", "Not Now", "Close"])
        guard tapFirst(contacts, ["Add", "+", "New Contact"]) else { XCTFail("no Add button"); return }
        sleep(2)
        let first = contacts.textFields.matching(NSPredicate(format: "label ==[c] 'First name' OR placeholderValue ==[c] 'First name'")).firstMatch
        guard first.waitForExistence(timeout: 8) else { XCTFail("no First name field"); return }
        first.tap(); sleep(2)
        guard switchTo(contacts, ours) else { XCTFail("our keyboard did not come up"); return }
        print("MNATIVE first ours text=\(el(contacts, "key.space").exists) email=\(el(contacts, "key.bx:@").exists)")
        for (row, want, tag) in [("add email", "key.bx:@", "email"), ("add url", "key.bx:.com", "url")] {
            let add = contacts.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", row)).firstMatch
            var tries = 0
            while !(add.exists && add.isHittable) && tries < 4 { contacts.swipeUp(velocity: .slow); sleep(1); tries += 1 }
            guard add.exists && add.isHittable else { print("MNATIVE \(tag) row not found"); continue }
            add.tap(); sleep(2)
            let up = ours(contacts)
            let ok = up && el(contacts, want).exists
            print("MNATIVE \(tag) ours=\(up) follows=\(ok)")
            dumpOurs(contacts, "native-\(tag)-ours"); shot("m-native-\(tag)-ours")
        }
        _ = tapFirst(contacts, ["Cancel"]); sleep(1)
        _ = tapFirst(contacts, ["Discard Changes", "Delete Contact", "Discard"])
    }
}
