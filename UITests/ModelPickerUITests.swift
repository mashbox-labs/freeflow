import XCTest

/// The model picker in setup and in Settings > Models, driven through the real UI. The simulator reports the
/// Mac's memory, so each launch sets the memory a real device reports (FF_SIM_MEMORY_GIB, simulator builds only):
/// 5.6 GiB = a 6 GB iPhone, 3.7 GiB = 4 GB, 11.2 GiB = 12 GB. The simulator's language is English.
final class ModelPickerUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(onboarded: Bool, memoryGiB: Double, light: Bool = false) {
        app = XCUIApplication()
        // Setup starts on its first page (it resumes on the saved step otherwise).
        app.launchArguments = ["-onboarded", onboarded ? "YES" : "NO"] + (onboarded ? [] : ["-setup.step", "0"])
        // No saved pick from an earlier run on this simulator: the recommendation must be what the picker shows.
        app.launchArguments += ["-activeModel", ""]
        if light { app.launchArguments += ["-appearance", "light"] }
        app.launchEnvironment["FF_SIM_MEMORY_GIB"] = String(memoryGiB)
        app.launch()
        // Same guard as FreeFlowUITests: right after an install iOS can start the app itself, without these
        // arguments. If the first screen is the one the arguments rule out, launch once more.
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
        let screen = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: screen)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["FF_SHOTS_DIR"] {
            try? screen.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func scrollTo(_ e: XCUIElement, max: Int = 10) {
        var n = 0
        while !e.isHittable && n < max { app.swipeUp(); n += 1 }
    }

    /// Steps through setup until the on-device AI page, where the picker lives.
    private func openSetupPicker() {
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 30))
        var n = 0
        while !element("modelPicker").exists && n < 5 {
            app.buttons["onboarding.next"].tap()
            sleep(1)
            n += 1
        }
        XCTAssertTrue(element("modelPicker").waitForExistence(timeout: 15), "the picker did not appear in setup")
    }

    /// Recommended first, then the rest by download size, read from where they sit on screen.
    private func assertOrder(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        let ys = ids.map { element("model.\($0)").frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "rows are not in the order \(ids): \(ys)", file: file, line: line)
        XCTAssertEqual(Set(ys).count, ids.count, "two rows share a position: \(ys)", file: file, line: line)
    }

    /// 6 GB device in setup: Parakeet recommended and pre-selected with its reason, large marked too big and
    /// not pickable, small still pickable; picking small (nothing downloaded yet) moves the selection.
    func testP1SetupSixGB() {
        launch(onboarded: false, memoryGiB: 5.6)
        openSetupPicker()
        XCTAssertTrue(element("model.medium").waitForExistence(timeout: 10))
        assertOrder(["medium", "large", "small"])
        let reason = element("recommendReason")
        XCTAssertTrue(reason.exists)
        XCTAssertTrue(reason.label.contains("6 GB of memory"), reason.label)
        XCTAssertTrue(reason.label.contains("English"), reason.label)
        XCTAssertTrue(app.buttons["select.medium"].isSelected, "the recommended model should be pre-selected")
        XCTAssertTrue(app.buttons["download.medium"].exists)
        scrollTo(element("model.medium"))
        shot("p1-setup-6gb-recommended")

        let tooBig = element("tooBig.large")
        scrollTo(tooBig)
        XCTAssertTrue(tooBig.exists, "large should be marked too big on 6 GB")
        XCTAssertFalse(app.buttons["select.large"].isEnabled, "a too-big model must not be pickable")
        XCTAssertFalse(app.buttons["download.large"].exists, "a too-big model must not offer a download")
        XCTAssertTrue(app.staticTexts["Needs 8 GB of memory. This iPhone has 6 GB."].exists
                      || app.staticTexts["Needs 8 GB of memory. This iPad has 6 GB."].exists)
        shot("p1-setup-6gb-too-big")

        XCTAssertFalse(element("tooBig.small").exists)
        let small = app.buttons["select.small"]
        scrollTo(small)
        small.tap()
        sleep(1)
        XCTAssertTrue(small.isSelected, "picking small should select it while nothing is downloaded")
        XCTAssertFalse(app.buttons["select.medium"].isSelected)
        XCTAssertTrue(app.buttons["download.small"].exists)
        shot("p1-setup-6gb-picked-small")
        // Put the pick back to the recommendation for the next tests.
        let medium = app.buttons["select.medium"]
        var n = 0
        while !medium.isHittable && n < 10 { app.swipeDown(); n += 1 }
        medium.tap()
        sleep(1)
        XCTAssertTrue(medium.isSelected)
    }

    /// 4 GB device, light look: small recommended, large too big, Parakeet still pickable.
    func testP2SetupFourGBLight() {
        launch(onboarded: false, memoryGiB: 3.7, light: true)
        openSetupPicker()
        XCTAssertTrue(element("model.small").waitForExistence(timeout: 10))
        assertOrder(["small", "large", "medium"])
        XCTAssertTrue(element("recommendReason").label.contains("4 GB of memory"), element("recommendReason").label)
        scrollTo(element("model.small"))
        shot("p2-setup-4gb-light-recommended")
        scrollTo(element("tooBig.large"))
        XCTAssertTrue(element("tooBig.large").exists)
        XCTAssertFalse(element("tooBig.medium").exists, "Parakeet fits a 4 GB device; it is just not the default there")
        XCTAssertTrue(app.buttons["select.medium"].isEnabled)
        shot("p2-setup-4gb-light-list")
    }

    /// 12 GB device: Settings > Models opens the Models page (10-29 redo): nothing too big, Parakeet recommended with
    /// its reason, every Core ML model listed with a Download button.
    func testP3SettingsModelsTwelveGB() {
        launch(onboarded: true, memoryGiB: 11.2)
        let settings = app.tabBars.buttons["Settings"]
        if settings.waitForExistence(timeout: 20) { settings.tap() } else { app.buttons["Settings"].firstMatch.tap() }
        let link = element("settings.models")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Settings has no Models row")
        shot("p3-settings")
        link.tap()
        XCTAssertTrue(element("modelsPage").waitForExistence(timeout: 10), "Settings > Models did not open the Models page")
        XCTAssertTrue(element("recommendReason").label.contains("12 GB of memory"), element("recommendReason").label)
        for id in ["small", "medium", "large", "whisper-tiny", "whisper-base", "whisper-small-f16"] {
            XCTAssertTrue(element("model.\(id)").exists, "\(id) has no card")
            XCTAssertFalse(element("tooBig.\(id)").exists, "\(id) should fit 12 GB")
        }
        shot("p3-settings-models-12gb-top")
    }

    // MARK: The Models page (2026-10-29)

    /// Launch for the Models page: optional memory and free space (simulator test hooks), dark unless `light`.
    private func launchModels(memoryGiB: Double? = nil, freeDiskGB: Double? = nil, light: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES"]
        if light { app.launchArguments += ["-appearance", "light"] }
        if let memoryGiB { app.launchEnvironment["FF_SIM_MEMORY_GIB"] = String(memoryGiB) }
        if let freeDiskGB { app.launchEnvironment["FF_SIM_FREE_DISK_GB"] = String(freeDiskGB) }
        app.launch()
        let mic = app.buttons["micButton"], setup = app.buttons["onboarding.next"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !mic.exists && !setup.exists { usleep(250_000) }
        if setup.exists && !mic.exists {
            XCTContext.runActivity(named: "App opened without the test's launch arguments; launching again") { _ in
                app.terminate()
                app.launch()
            }
        }
        XCTAssertTrue(mic.waitForExistence(timeout: 20), "Free Flow did not open on Dictate")
        let tab = app.tabBars.buttons["Models"]
        let models = tab.exists ? tab : app.buttons["Models"].firstMatch
        let until = Date().addingTimeInterval(10)
        while Date() < until && !(models.exists && models.isHittable) { usleep(250_000) }
        models.tap()
        XCTAssertTrue(element("modelsPage").waitForExistence(timeout: 10), "the Models tab did not open the Models page")
        sleep(1)
    }

    private func showOnly(_ section: String) {
        let chip = app.buttons["filter.\(section)"]
        var n = 0
        while !chip.isHittable && n < 6 { app.swipeDown(); n += 1 }
        chip.tap()
        sleep(1)
        XCTAssertTrue(chip.isSelected, "filter \(section) did not take")
    }

    static let allIDs = ["parakeet-ultra", "phonon-2", "parakeet-redux", "bark-3.0-clean", "bark-3-pro",
                         "parakeet-gguf-q4_0", "parakeet-gguf-q4_k", "parakeet-gguf-q8_0"]
    /// Build 23: the filter row by company (ids filter.<maker>), and which models each one shows.
    static let byMaker = ["moondream": ["parakeet-ultra", "parakeet-redux"], "fermion-research": ["phonon-2"],
                          "conway-research": ["bark-3.0-clean", "bark-3-pro"],
                          "nvidia": ["parakeet-gguf-q4_0", "parakeet-gguf-q4_k", "parakeet-gguf-q8_0"]]

    /// Every model is a card with size, quantization, engine, languages and the simulator speed; free space on top as
    /// a nearly full iPad had it (6.75 GB of 128 GB). Screens in dark, then light. Env FF_SHOT_PREFIX names the device.
    func testM1ModelsPageCards() {
        let prefix = ProcessInfo.processInfo.environment["FF_SHOT_PREFIX"] ?? "m1"
        for light in [false, true] {
            let look = light ? "light" : "dark"
            launchModels(memoryGiB: 7.5, freeDiskGB: 6.75, light: light)
            let free = element("freeSpace")
            XCTAssertTrue(free.waitForExistence(timeout: 10))
            XCTAssertTrue(free.value as? String == "6.75 GB free of 128 GB", "free space reads \(String(describing: free.value))")
            XCTAssertTrue(element("inUse").exists)
            XCTAssertTrue(element("liveStats").exists)
            for section in ["parakeet", "bark"] { XCTAssertTrue(element("section.\(section)").exists, section) }
            // Build 14 (2026-10-30): one compact row per model, no test numbers; the chevron opens the details.
            for id in Self.allIDs {
                XCTAssertTrue(element("model.\(id)").exists, "\(id) has no card")
                for part in ["size", "runtime", "purpose", "expand"] {
                    XCTAssertTrue(element("\(part).\(id)").exists, "\(id) card has no \(part)")
                }
                for numbers in ["simSpeed", "wer", "simSpeedLine", "measured"] {
                    XCTAssertFalse(element("\(numbers).\(id)").exists, "\(id) card shows test numbers (\(numbers))")
                }
            }
            XCTAssertTrue(element("recommended.parakeet-ultra").exists, "Parakeet Ultra is the pick for 8 GB + English")
            XCTAssertTrue(element("size.parakeet-gguf-q4_0").label.contains("356 MB"), element("size.parakeet-gguf-q4_0").label)
            XCTAssertTrue(element("runtime.parakeet-gguf-q4_0").label.contains("C++ fallback"), element("runtime.parakeet-gguf-q4_0").label)
            XCTAssertTrue(element("runtime.parakeet-ultra").label.contains("Neural Engine"), element("runtime.parakeet-ultra").label)
            shot("\(prefix)-\(look)-0-compact")
            for id in ["parakeet-gguf-q4_0", "parakeet-ultra"] {
                let chevron = app.buttons["expand.\(id)"]; scrollTo(chevron); chevron.tap()
            }
            XCTAssertTrue(element("quant.parakeet-gguf-q4_0").waitForExistence(timeout: 5))
            XCTAssertTrue(element("quant.parakeet-gguf-q4_0").label.contains("Q4_0"), element("quant.parakeet-gguf-q4_0").label)
            XCTAssertTrue(element("engine.parakeet-ultra").label.contains("Core ML"), element("engine.parakeet-ultra").label)
            XCTAssertTrue(element("licence.parakeet-ultra").exists)
            shot("\(prefix)-\(look)-0-expanded")
            for id in ["parakeet-gguf-q4_0", "parakeet-ultra"] {
                let chevron = app.buttons["expand.\(id)"]; scrollTo(chevron); chevron.tap()
            }
            app.swipeDown(); app.swipeDown(); sleep(1)
            shot("\(prefix)-\(look)-1-top")
            for (maker, ids) in Self.byMaker.sorted(by: { $0.key < $1.key }) {
                showOnly(maker)
                for id in Self.allIDs {
                    XCTAssertEqual(element("model.\(id)").exists, ids.contains(id), "filter \(maker): \(id)")
                }
                shot("\(prefix)-\(look)-2-\(maker)")
                app.swipeDown(); sleep(1)
            }
            showOnly("all")
            app.terminate()
        }
    }

    /// Download and delete one small model (Whisper tiny, 79 MB) through the real page; the model in use stays.
    /// 2026-11-03 (iPad build 34: Use did not switch to the model). Needs Parakeet Ultra and our Whisper on
    /// the simulator already. English device language: Use on Whisper says why it does not switch (never nothing).
    /// Build 38, a fresh install: setup shows exactly two cards, each with its download size, under one line
    /// on languages; never the full list. Build 39: our Whisper first (recommended, preselected) from 7.0 GiB, Parakeet
    /// Ultra second; on 6 GB devices Parakeet first, Whisper second. FF_M6_GIB picks the simulated memory (default 7.5).
    func testM6FirstRunChoice() {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "NO", "-setup.step", "0"]
        app.launchEnvironment["FF_SIM_MEMORY_GIB"] = ProcessInfo.processInfo.environment["FF_M6_GIB"] ?? "7.5"
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 30))
        var n = 0
        while !element("setupChoice").exists && n < 6 { app.buttons["onboarding.next"].tap(); sleep(1); n += 1 }
        XCTAssertTrue(element("setupChoice").waitForExistence(timeout: 15), "the two-model choice did not appear in setup")
        XCTAssertFalse(element("modelPicker").exists, "the full picker shows in setup")
        XCTAssertTrue(element("setupLanguages").exists, "no language line above the cards")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "select."))
        XCTAssertEqual(cards.count, 2, "setup does not show exactly two cards")
        let gib = Double(app.launchEnvironment["FF_SIM_MEMORY_GIB"]!) ?? 0
        let parakeet = app.buttons["select.parakeet-ultra"], whisper = app.buttons["select.whisper-turbo-ane"]
        XCTAssertTrue(element("setupSize.parakeet-ultra").label.contains("632 MB"), element("setupSize.parakeet-ultra").label)
        let first = cards.element(boundBy: 0), second = cards.element(boundBy: 1)
        let firstID = String(first.identifier.dropFirst("select.".count)), secondID = String(second.identifier.dropFirst("select.".count))
        XCTAssertTrue(first.isSelected, "the first card is not preselected")
        XCTAssertFalse(second.isSelected)
        XCTAssertLessThan(element("model.\(firstID)").frame.minY, element("model.\(secondID)").frame.minY, "cards out of order")
        if gib >= 7 {
            // Build 39: 8 GB devices and up: our Whisper first and recommended, Parakeet Ultra second.
            XCTAssertEqual([firstID, secondID], ["whisper-turbo-ane", "parakeet-ultra"])
            XCTAssertTrue(element("setupSize.whisper-turbo-ane").label.contains("964 MB"), element("setupSize.whisper-turbo-ane").label)
            XCTAssertTrue(element("setupLanguages").label.hasPrefix("Pick by the languages you speak. Whisper"), element("setupLanguages").label)
        } else if gib >= 5 {
            XCTAssertEqual([firstID, secondID], ["parakeet-ultra", "whisper-turbo-ane"])
            XCTAssertTrue(element("setupLanguages").label.hasPrefix("Pick by the languages you speak. Parakeet"), element("setupLanguages").label)
        } else {
            XCTAssertNotEqual(secondID, "whisper-turbo-ane", "Whisper offered where it cannot run")
        }
        let card = element("setupChoice")
        var k = 0
        while card.frame.minY < 110 && k < 12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53)))
            sleep(1); k += 1
        }
        shot("39-setup-choice")
        second.tap(); sleep(1)
        XCTAssertTrue(second.isSelected, "picking the second card did not move the selection")
        first.tap(); sleep(1)
        XCTAssertTrue(first.isSelected)
        _ = (parakeet, whisper)
    }

    func testM4UseWhisperSwitches() {
        launch(onboarded: true, memoryGiB: 7.5)
        app.buttons["Models"].firstMatch.tap()
        let use = app.buttons["use.whisper-turbo-ane"]
        scrollTo(use)
        XCTAssertTrue(use.waitForExistence(timeout: 20), "no Use button on our Whisper (not downloaded on this simulator?)")
        use.tap()
        // 2026-11-03: Use always switches. The Use button goes away once it is the model in use.
        XCTAssertTrue(use.waitForNonExistence(timeout: 10), "Use did not switch to our Whisper")
        XCTAssertFalse(app.alerts["Language"].exists, "a conflict popup with Automatic (Whisper speaks every language)")
        shot("m4-use-whisper")
    }

    /// 2026-11-03 (a popup that changes it right there): Thai pinned, Use on Parakeet Ultra (which
    /// doesn't speak Thai) switches and offers Automatic in one tap. Needs Ultra and our Whisper on the simulator.
    func testM5LanguageConflictOneTap() {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES", "-speechLanguage", "th", "-activeModel", "whisper-turbo-ane"]
        app.launchEnvironment["FF_SIM_MEMORY_GIB"] = "7.5"
        app.launch()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 30))
        app.buttons["Models"].firstMatch.tap()
        let use = app.buttons["use.parakeet-ultra"]
        scrollTo(use)
        XCTAssertTrue(use.waitForExistence(timeout: 20))
        use.tap()
        let alert = app.alerts["Language"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no popup for a language Parakeet can't speak")
        print("FFCONFLICT " + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        shot("m5-conflict")
        alert.buttons["Use Automatic"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(use.waitForNonExistence(timeout: 10), "Use did not switch to Parakeet Ultra")
    }

    func testM2DownloadThenDeleteSmallModel() {
        launchModels()
        let id = "whisper-tiny"
        let inUseBefore = element("inUse").label
        showOnly("whisper")
        let verified = element("verified.\(id)")
        if verified.exists {
            // Left over from an earlier run: delete first so the download is real.
            deleteModel(id)
        }
        let download = app.buttons["download.\(id)"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        scrollTo(download)
        download.tap()
        // A tight-space alert does not apply here (the simulator has the Mac's free space).
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "unexpected alert")
        XCTAssertTrue(verified.waitForExistence(timeout: 600), "Whisper tiny did not finish downloading and verifying")
        XCTAssertTrue(app.buttons["delete.\(id)"].exists)
        let hadModel = inUseBefore.hasPrefix("In use")
        if hadModel {
            XCTAssertTrue(app.buttons["use.\(id)"].exists, "a fresh download must not take over from the model in use")
            XCTAssertEqual(element("inUse").label, inUseBefore, "the model in use changed after a download")
        }
        scrollTo(element("model.\(id)"))
        shot("m2-downloaded")
        deleteModel(id)
        XCTAssertTrue(app.buttons["download.\(id)"].waitForExistence(timeout: 10), "Delete did not remove Whisper tiny")
        XCTAssertFalse(element("verified.\(id)").exists)
        shot("m2-deleted")
        if hadModel { XCTAssertEqual(element("inUse").label, inUseBefore, "the model in use changed after a delete") }
    }

    private func deleteModel(_ id: String) {
        let delete = app.buttons["delete.\(id)"]
        scrollTo(delete)
        delete.tap()
        // The iOS 26.5 simulator lists an alert's button twice ("Multiple matching elements found").
        let confirm = app.alerts.firstMatch.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no delete confirmation")
        shot("m2-confirm-delete-\(id)")
        confirm.tap()
        sleep(1)
    }

    /// Nearly full device (1.5 GB free): a 356 MB download asks first and Cancel starts nothing; a 1.39 GB model that
    /// cannot fit shows why and offers no download.
    func testM3LowDiskWarns() {
        launchModels(freeDiskGB: 1.5)
        XCTAssertTrue(element("freeSpace").value as? String == "1.50 GB free of 128 GB", String(describing: element("freeSpace").value))
        showOnly("parakeet")
        let id = "parakeet-gguf-q4_0"
        if element("verified.\(id)").exists { deleteModel(id) }
        let warn = element("diskWarning.\(id)")
        XCTAssertTrue(warn.waitForExistence(timeout: 5), "no low-space line on the 356 MB card")
        XCTAssertTrue(warn.label.contains("Leaves 1.14 GB free"), warn.label)
        let download = app.buttons["download.\(id)"]
        scrollTo(download)
        download.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no question before a download that leaves under 1.5 GB")
        XCTAssertTrue(alert.buttons["Download anyway"].firstMatch.exists)
        shot("m3-low-disk-alert")
        alert.buttons["Cancel"].firstMatch.tap()
        sleep(2)
        XCTAssertFalse(element("progress.\(id)").exists, "Cancel started a download")
        XCTAssertTrue(app.buttons["download.\(id)"].exists)

        showOnly("liquid")
        let big = "lfm3-audio-q4_0"
        let noRoom = element("diskWarning.\(big)")
        scrollTo(noRoom)
        XCTAssertTrue(noRoom.label.contains("Needs 1.59 GB free"), noRoom.label)
        XCTAssertFalse(app.buttons["download.\(big)"].isEnabled, "a model that cannot fit offers a download")
        shot("m3-no-room")
    }

    /// Speed walks: deletes FF_TEST_MODEL after FreeFlowUITests.test2 measured it, so the simulator does not fill up.
    func testM9DeleteTestModel() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["FF_TEST_MODEL"])
        launchModels()
        showOnly(id == "medium" || id.hasPrefix("parakeet") ? "parakeet" : (id.hasPrefix("lfm") ? "liquid" : "whisper"))
        XCTAssertTrue(element("verified.\(id)").waitForExistence(timeout: 5), "\(id) is not downloaded")
        deleteModel(id)
        XCTAssertTrue(app.buttons["download.\(id)"].waitForExistence(timeout: 10), "\(id) was not deleted")
    }
}
