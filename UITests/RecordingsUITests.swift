import XCTest

/// Never lose audio, through the real UI, with the recorded speech clip fed in place of the mic (FF_AUDIO_FILE)
/// and real transcription. Proven here: the app killed mid-recording, the X, and the interruption notifications iOS
/// posts for a call (posted by the app itself under -ffSimulateInterruption). Not provable in the simulator: a real
/// phone, FaceTime or WhatsApp call, Siri, iOS killing the app in the background, a locked device. Those need a phone.
final class RecordingsUITests: XCTestCase {
    var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private static var relaunchedAfterInstall = false

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES"] + extra
        if let file = env["FF_AUDIO_FILE"] { app.launchEnvironment["FF_AUDIO_FILE"] = file }
        app.launch()
        // Build 23 (10-31: R2's first launch after the install arrived without FF_AUDIO_FILE, so it recorded the simulator's
        // mic, not the test recording): the first launch of each run is always done twice, as FreeFlowUITests does.
        if !Self.relaunchedAfterInstall {
            Self.relaunchedAfterInstall = true
            app.terminate()
            app.launch()
        }
        // Right after an install iOS can start the app by itself without our arguments (see FreeFlowUITests.launch).
        if !app.buttons["micButton"].waitForExistence(timeout: 20) {
            XCTContext.runActivity(named: "App opened without the test's launch arguments; launching again") { _ in
                app.terminate()
                app.launch()
            }
        }
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 20))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tab(_ name: String) {
        let bar = app.tabBars.buttons[name]
        if bar.exists { bar.tap() } else { app.buttons[name].firstMatch.tap() }
        sleep(1)
    }

    private func scrollTo(_ e: XCUIElement) {
        var n = 0
        while !e.isHittable && n < 8 { app.swipeUp(); n += 1 }
    }

    /// The speech model from Models (downloaded once per simulator; a later run finds it verified).
    private func ensureModel() {
        let model = env["FF_TEST_MODEL"] ?? "parakeet-ultra"
        tab("Models")
        let verified = element("verified.\(model)")
        if !verified.waitForExistence(timeout: 3) {
            let download = app.buttons["download.\(model)"]
            scrollTo(download)
            download.tap()
            XCTAssertTrue(verified.waitForExistence(timeout: 1500), "model did not finish downloading and verifying")
        }
        let use = app.buttons["use.\(model)"]
        if use.exists { scrollTo(use); use.tap() }
        tab("Dictate")
    }

    /// Starts each test from an empty Recent recordings, using the list's own Delete.
    private func clearRecent() {
        tab("History")
        var n = 0
        while app.buttons["clip.delete"].firstMatch.waitForExistence(timeout: 2) && n < 30 {
            app.buttons["clip.delete"].firstMatch.tap()
            sleep(1)
            n += 1
        }
        XCTAssertFalse(element("clip.row").exists)
        tab("Dictate")
    }

    private func listen(seconds: UInt32) {
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["cancelButton"].waitForExistence(timeout: 15))
        sleep(seconds)
    }

    /// Retry in Recent recordings: the saved audio through the model gives the clip's words.
    private func retryAndRead(_ tag: String) {
        let retry = app.buttons["clip.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        // Build 23: Retry is one button for the model in use (no menu of models).
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " (in use)")).firstMatch.waitForExistence(timeout: 2),
                       "Retry offers no choice of models")
        let text = element("clip.text")
        XCTAssertTrue(text.waitForExistence(timeout: 180), "Retry wrote no text")
        print("FFRETRY \(tag) " + text.label)
        XCTAssertTrue(text.label.lowercased().contains("americans"), text.label)
        XCTAssertEqual(element("clip.status").label, "Transcribed")
        shot("\(tag)-retried")
    }

    /// The app is killed while recording (no finish, no X, no cleanup); the next launch has the clip.
    func testR1KilledMidRecordingKeepsClip() {
        launch()
        ensureModel()
        clearRecent()
        listen(seconds: 5)
        shot("r1-listening")
        app.terminate()
        launch()
        XCTAssertTrue(element("recoveryPrompt").waitForExistence(timeout: 10), "the next launch offers the cut-off recording")
        XCTAssertEqual(element("prompt.title").label, "Free Flow closed before your recording finished. Transcribe it?")
        shot("r1-prompt")
        app.buttons["prompt.later"].tap()
        XCTAssertTrue(element("recoveryPrompt").waitForNonExistence(timeout: 5))
        tab("History")
        XCTAssertTrue(element("clip.row").waitForExistence(timeout: 5))
        XCTAssertEqual(element("clip.status").label, "Free Flow closed before it finished")
        shot("r1-recent")
        retryAndRead("r1")
        app.buttons["clip.delete"].firstMatch.tap()
        XCTAssertTrue(element("clip.row").waitForNonExistence(timeout: 5), "Delete removes it")
    }

    /// X cancels the text, never the audio.
    func testR2XKeepsClip() {
        launch()
        ensureModel()
        clearRecent()
        listen(seconds: 5)
        app.buttons["cancelButton"].tap()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("transcriptText").exists, "X still cancels the text")
        XCTAssertFalse(element("recoveryPrompt").exists, "X is your choice: no question asked")
        tab("History")
        XCTAssertTrue(element("clip.row").waitForExistence(timeout: 5))
        XCTAssertEqual(element("clip.status").label, "You tapped X")
        shot("r2-recent")
        retryAndRead("r2")
    }

    /// Build 23 (Retry with Whisper large while Whisper small was being prepared prepared both at once).
    /// Retry tapped while another pick is being prepared: the recording is kept for that pick ("Saved. ...") and is
    /// written by it once it is ready; the model that was in use is not loaded again. FF_TEST_MODEL2 (default large)
    /// must be on the simulator with its Core ML cache cleared, so its first prepare takes a while.
    func testR4RetryWhileAnotherPickPreparesWaitsForThePick() {
        launch()
        ensureModel()
        clearRecent()
        listen(seconds: 5)
        app.buttons["cancelButton"].tap()
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 10))
        let first = env["FF_TEST_MODEL"] ?? "parakeet-ultra", second = env["FF_TEST_MODEL2"] ?? "phonon-2"
        tab("Models")
        let use = app.buttons["use.\(second)"]
        scrollTo(use)
        XCTAssertTrue(use.waitForExistence(timeout: 5), "\(second) must be downloaded on this simulator")
        use.tap()
        tab("History")
        let retry = app.buttons["clip.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        let status = element("clip.status")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        print("FFRETRY r4 status after Retry: " + status.label)
        shot("r4-kept")
        XCTAssertTrue(status.label.hasPrefix("Saved. Free Flow writes this when") || status.label == "Transcribing" || status.label == "Transcribed",
                      status.label)
        tab("Models")
        XCTAssertFalse(element("loading.\(first)").exists, "the model that was in use is not loaded again")
        tab("History")
        let text = element("clip.text")
        XCTAssertTrue(text.waitForExistence(timeout: 300), "the kept recording was not written once the pick was ready")
        XCTAssertEqual(element("clip.status").label, "Transcribed")
        print("FFRETRY r4 " + text.label)
        shot("r4-written")
        tab("Models")                                   // leave the simulator on the first model
        let back = app.buttons["use.\(first)"]
        scrollTo(back)
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    /// A call (simulated: the same interruption notifications iOS posts) stops the recording; the audio up to it
    /// is kept, and when it ends Free Flow asks "Transcribe it?".
    func testR3SimulatedCallKeepsClip() {
        launch(["-ffSimulateInterruption", "5"])
        ensureModel()
        clearRecent()
        app.buttons["micButton"].tap()
        XCTAssertTrue(app.buttons["cancelButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("recoveryPrompt").waitForExistence(timeout: 30), "no question after the call ended")
        XCTAssertEqual(element("prompt.title").label, "Recording stopped by a call or another app. Transcribe it?")
        XCTAssertTrue(app.buttons["micButton"].exists, "the mic is off after the call")
        shot("r3-prompt")
        app.buttons["prompt.transcribe"].tap()
        let transcript = app.staticTexts["transcriptText"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 180))
        print("FFRETRY r3 " + transcript.label)
        XCTAssertTrue(transcript.label.lowercased().contains("americans"), transcript.label)
        shot("r3-transcribed")
        tab("History")
        XCTAssertTrue(element("clip.row").waitForExistence(timeout: 5))
        XCTAssertEqual(element("clip.status").label, "Transcribed")
        shot("r3-recent")
    }
}
