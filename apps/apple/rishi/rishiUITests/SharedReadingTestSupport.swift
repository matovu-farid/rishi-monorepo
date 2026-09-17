import Foundation
import XCTest

#if os(macOS)
import AppKit
#endif

#if canImport(Darwin)
import Darwin
#endif

/// Small, role-aware UI harness for the native shared-reading peers. The
/// harness receives only disposable role credentials and coordination values;
/// it never writes a bearer token or session object into the app.
final class SharedReadingTestSupport {
    enum Role: String { case owner, participant }

    private static let appGroupIdentifier = "group.org.fidexa.rishi"
    private static let stagedFixtureName = "rishi-e2e-fixture"

    private struct Manifest: Decodable {
        struct Account: Decodable { let email: String }
        struct Destination: Decodable { let rawValue: String }
        let runID: String
        let owner: Account
        let participant: Account
        let rendezvousPath: String
    }

    private struct Invite: Codable {
        let runID: String
        let inviteToken: String
    }

    private struct ParticipantReady: Codable {
        let runID: String
        let ready: Bool
    }

    private struct ProgressReady: Codable {
        let runID: String
        let sequence: Int64
    }

    private struct PlaybackReady: Codable {
        let runID: String
        let state: String
    }

    private enum RendezvousTestError: Error {
        case timedOut
        case invalidInviteLink
        case relayUnavailable
    }

    private var stagedFixtureURL: URL?

    deinit {
        removeStagedFixture()
    }

    private var manifest: Manifest {
        get throws {
            let path = ProcessInfo.processInfo.environment["RISHI_E2E_MANIFEST_PATH"]
                ?? ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--rishi-e2e-manifest=") })?.replacingOccurrences(of: "--rishi-e2e-manifest=", with: "")
            guard let path, !path.isEmpty else { throw XCTSkip("shared-reading host manifest is not configured") }
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    private var runID: String? {
        if let value = ProcessInfo.processInfo.environment["RISHI_E2E_RUN_ID"], !value.isEmpty {
            return value
        }
        return try? manifest.runID
    }

    /// Leaves a host-readable breadcrumb when an XCTest run is forcefully
    /// stopped before Xcode can finalize its result bundle. Stage names are
    /// fixed literals only; credentials, tokens, and book metadata never go
    /// into this trace.
    func recordStage(_ stage: String) {
        guard let path = ProcessInfo.processInfo.environment["RISHI_E2E_STAGE_LOG"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let line = "\(stage)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data)
        }
    }

    private var relayIsConfigured: Bool {
        relayPort != nil && relaySecret != nil
    }

    private var relayPort: UInt16? {
        guard let value = ProcessInfo.processInfo.environment["RISHI_E2E_RENDEZVOUS_PORT"] else { return nil }
        return UInt16(value)
    }

    private var relaySecret: String? {
        guard let value = ProcessInfo.processInfo.environment["RISHI_E2E_RENDEZVOUS_SECRET"], !value.isEmpty else { return nil }
        return value
    }

    private func requiredRunID() throws -> String {
        guard let runID, !runID.isEmpty else { throw RendezvousTestError.relayUnavailable }
        return runID
    }

    private var rendezvousURL: URL { URL(fileURLWithPath: (try? manifest.rendezvousPath) ?? "") }
    private var participantReadyURL: URL { rendezvousURL.appendingPathExtension("participant-ready") }
    private var participantProgressURL: URL { rendezvousURL.appendingPathExtension("participant-progress") }
    private var participantRejoinedURL: URL { rendezvousURL.appendingPathExtension("participant-rejoined") }
    private var participantPlaybackURL: URL { rendezvousURL.appendingPathExtension("participant-playback") }

    @MainActor
    func launch(role: Role) throws -> XCUIApplication {
        recordStage("launch.begin")
        let app = XCUIApplication()
        // Catalyst can retain the app process between xcodebuild sessions.
        // Terminate it before applying launch arguments so the real-auth and
        // reset flags cannot be silently ignored by an already-running app.
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 30)
        app.launchArguments += ["--rishi-e2e-real-auth"]
        if ProcessInfo.processInfo.environment["RISHI_E2E_RESET_ON_LAUNCH"] == "1" {
            app.launchArguments += ["--rishi-e2e-reset"]
        }
        if role == .owner,
           let fixture = ProcessInfo.processInfo.environment["RISHI_E2E_FIXTURE_PATH"],
           !fixture.isEmpty {
            let staged = try stageFixture(at: URL(fileURLWithPath: fixture))
            stagedFixtureURL = staged
            app.launchArguments += ["--rishi-e2e-fixture=\(staged.path)"]
        }
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launchEnvironment["RISHI_E2E_REAL_AUTH"] = "1"
        app.launchEnvironment["RISHI_E2E_ROLE"] = role.rawValue
        // The host keeps credentials out of the on-disk manifest, but the
        // launched app must receive the same disposable values so its
        // DEBUG-only visible form can prefill them without Catalyst keyboard
        // synthesis.
        if let email = ProcessInfo.processInfo.environment["RISHI_E2E_EMAIL"], !email.isEmpty {
            app.launchEnvironment["RISHI_E2E_EMAIL"] = email
        }
        if let password = ProcessInfo.processInfo.environment["RISHI_E2E_PASSWORD"], !password.isEmpty {
            app.launchEnvironment["RISHI_E2E_PASSWORD"] = password
        }
        if let secret = ProcessInfo.processInfo.environment["RISHI_E2E_TEST_AUTH_SECRET"], !secret.isEmpty {
            app.launchEnvironment["RISHI_E2E_TEST_AUTH_SECRET"] = secret
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        bringToFront(app)
        recordStage("launch.foreground")
        return app
    }

    @MainActor
    func login(_ app: XCUIApplication, role: Role) throws {
        recordStage("login.begin")
        let account: (email: String, password: String)
        if let email = ProcessInfo.processInfo.environment["RISHI_E2E_EMAIL"],
           let password = ProcessInfo.processInfo.environment["RISHI_E2E_PASSWORD"],
           !email.isEmpty, !password.isEmpty {
            account = (email, password)
        } else {
            // The native host passes credentials directly to each XCTest
            // process. Never fall back to password files in the run folder.
            throw XCTSkip("shared-reading XCTest credentials are not configured")
        }
        bringToFront(app)
        // Real-auth service construction can take longer on a cold Catalyst
        // launch than the fake-auth UI-test path. Wait for the actual form
        // instead of typing into a still-loading root view.
        let email = waitForEmailField(app, timeout: 120)
        recordStage("login.form-visible")
        let password = app.secureTextFields["e2e-password-field"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        if (email.value as? String) != account.email {
            activate(email)
            email.typeText(account.email)
        }
        if let value = password.value as? String, value.isEmpty {
            activate(password)
            password.typeText(account.password)
        }
        // Submit through the visible SwiftUI control. Return-key synthesis is
        // flaky on Catalyst (and can time out after the app loses focus),
        // while this keeps the test on the same explicit UI path a user uses.
        let submit = app.buttons["e2e-email-password-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(15)
        while !submit.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(submit.isEnabled, "Email/password sign-in did not become enabled")
        // Catalyst reports this window as AX-disabled even when its controls
        // are visible. The coordinate-click fallback did not invoke this
        // SwiftUI button (the test remained on the login form without an
        // in-flight state or error). XCTest's direct button action does.
        submit.tap()
        recordStage("login.submit-tapped")
        XCTAssertTrue(
            email.waitForNonExistence(timeout: 60),
            "Visible email/password sign-in did not leave the signed-out form"
        )
        recordStage("login.form-dismissed")
        // A newly provisioned account receives the trial-credit explanation
        // on its first signed-in launch. Dismiss it before exercising the
        // import control; otherwise Catalyst exposes the library underneath
        // the sheet but sends the tap to the still-present onboarding UI.
        let trialGotIt = app.buttons["onboarding-no-card-trial-gotit"]
        if trialGotIt.waitForExistence(timeout: 5) {
            activate(trialGotIt)
        }
        // A fresh account must explicitly grant this visible consent before
        // the app performs its first inbound library sync. The E2E scenario
        // chooses the same affirmative action a user can choose; it does not
        // seed a consent marker or bypass the sync gate.
        let dataUseConsent = app.buttons["data-use-consent-allow"]
        if dataUseConsent.waitForExistence(timeout: 15) {
            activate(dataUseConsent)
            XCTAssertTrue(
                dataUseConsent.waitForNonExistence(timeout: 15),
                "Data-use consent did not complete"
            )
        }
        XCTAssertTrue(app.buttons["e2e-import-shared-reading-book"].waitForExistence(timeout: 45)
                      || app.staticTexts["Your library is empty"].waitForExistence(timeout: 5))
        recordStage("login.library-visible")
    }

    @MainActor
    private func waitForEmailField(_ app: XCUIApplication, timeout: TimeInterval) -> XCUIElement {
        // On a cold Catalyst launch, querying an identifier directly while
        // the app has no text-field descendants can make XCTest fail with a
        // fatal "no matching snapshot" error instead of returning false.
        // Wait for the first field to exist before resolving platform-specific
        // identifiers.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: timeout))
        let identified = app.textFields["e2e-email-field"]
        if identified.waitForExistence(timeout: min(timeout, 10)) {
            return identified
        }

        // Catalyst can flatten a SwiftUI container's accessibility identifier
        // onto its descendants. The visible placeholder remains stable and
        // is the correct fallback for that platform behavior.
        let labelled = app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Email'")
        ).firstMatch
        XCTAssertTrue(labelled.waitForExistence(timeout: max(timeout - 10, 1)))
        return labelled
    }

    @MainActor
    // Catalyst can report the app/window as disabled to XCTest while the
    // visible controls remain queryable. Coordinate click is the reliable
    // activation path there; ordinary tap is correct on iPhone.
    func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func bringToFront(_ app: XCUIApplication) {
        #if os(macOS)
        // XCTest's activate() can report success while Catalyst's AX window
        // remains disabled behind the launching test process. Activating the
        // actual NSRunningApplication makes the window key and enables input
        // synthesis before we touch the login controls.
        app.activate()
        if let running = NSRunningApplication(processIdentifier: app.processID) {
            _ = running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        #endif
    }

    @MainActor
    func importFixture(_ app: XCUIApplication) {
        let book = app.buttons.matching(NSPredicate(format: "identifier == 'library-book-cell'"))
        // The real-auth app imports the staged fixture from its signed-in
        // library task. This avoids relying on Catalyst's AX-disabled toolbar
        // click path while still exercising the real storage and sync upload.
        if book.firstMatch.waitForExistence(timeout: 120) { return }
        let importButton = app.buttons["e2e-import-shared-reading-book"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 30))
        activate(importButton)
        XCTAssertTrue(book.firstMatch.waitForExistence(timeout: 60))
    }

    @MainActor
    func waitForProvisionedBook(_ app: XCUIApplication) {
        // The native host has already uploaded and pushed the real fixture
        // through the production sync protocol. The sharing scenario only
        // waits for normal inbound sync; it must never exercise import UI.
        let book = app.buttons.matching(NSPredicate(format: "identifier == 'library-book-cell'"))
        XCTAssertTrue(book.firstMatch.waitForExistence(timeout: 120), "The pre-provisioned book did not arrive through sync")
    }

    @MainActor
    func createReadingLink(_ app: XCUIApplication) throws -> String {
        let directStart = app.buttons["e2e-start-shared-reading"]
        if directStart.waitForExistence(timeout: 10) {
            activate(directStart)
        } else {
            let book = app.buttons.matching(NSPredicate(format: "identifier == 'library-book-cell'" )).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 30))
            book.press(forDuration: 1.2)
            let start = app.buttons["Start Shared Reading"]
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            activate(start)
        }
        let create = app.buttons["shared-reading-create-link"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        activate(create)
        // The production API returns the canonical HTTPS universal link. Some
        // local/debug builds may expose the equivalent native scheme, so read
        // either supported representation and normalize it to the raw token.
        let link = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'rishi.fidexa.org/sharing/session?token=' OR label CONTAINS 'rishi://sharing/session?token='")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 45))
        let value = link.label
        guard let rawToken = Self.inviteToken(from: value) else {
            XCTFail("shared-reading invite link did not contain a valid raw token")
            throw RendezvousTestError.invalidInviteLink
        }
        try writeInvite(rawToken)
        activate(app.buttons["Done"])
        return rawToken
    }

    func waitForInvite(timeout: TimeInterval = 90) throws -> String {
        if let token = ProcessInfo.processInfo.environment["RISHI_E2E_INVITE_TOKEN"], !token.isEmpty {
            return token
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if relayIsConfigured,
               let value = try? relayRead(kind: "invite"),
               let token = value as? String,
               !token.isEmpty {
                return token
            }
            if let data = try? Data(contentsOf: rendezvousURL),
               let invite = try? JSONDecoder().decode(Invite.self, from: data),
               !invite.inviteToken.isEmpty {
                return invite.inviteToken
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("owner invite was not published before timeout")
        throw RendezvousTestError.timedOut
    }

    func waitForParticipantReady(timeout: TimeInterval = 90) throws {
        if relayIsConfigured {
            _ = try waitForRelayValue(kind: "participant-ready", timeout: timeout) { ($0 as? Bool) == true }
            return
        }
        let expectedRunID = try requiredRunID()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: participantReadyURL),
               let ready = try? JSONDecoder().decode(ParticipantReady.self, from: data),
               ready.runID == expectedRunID, ready.ready {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("participant did not join before timeout")
        throw RendezvousTestError.timedOut
    }

    func publishParticipantReady() throws {
        if relayIsConfigured {
            try relayPublish(kind: "participant-ready", value: true)
            return
        }
        let ready = ParticipantReady(runID: try requiredRunID(), ready: true)
        let data = try JSONEncoder().encode(ready)
        try data.write(to: participantReadyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: participantReadyURL.path)
    }

    func publishParticipantProgress(sequence: Int64) throws {
        if relayIsConfigured {
            try relayPublish(kind: "participant-progress", value: sequence)
            return
        }
        let progress = ProgressReady(runID: try requiredRunID(), sequence: sequence)
        let data = try JSONEncoder().encode(progress)
        try data.write(to: participantProgressURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: participantProgressURL.path)
    }

    func waitForParticipantProgress(timeout: TimeInterval = 90) throws {
        if relayIsConfigured {
            _ = try waitForRelayValue(kind: "participant-progress", timeout: timeout) { relayInt64($0) > 0 }
            return
        }
        let expectedRunID = try requiredRunID()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: participantProgressURL),
               let progress = try? JSONDecoder().decode(ProgressReady.self, from: data),
               progress.runID == expectedRunID, progress.sequence > 0 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("participant did not observe shared progress before timeout")
        throw RendezvousTestError.timedOut
    }

    func publishParticipantRejoined(sequence: Int64) throws {
        if relayIsConfigured {
            try relayPublish(kind: "participant-rejoined", value: sequence)
            return
        }
        let rejoined = ProgressReady(runID: try requiredRunID(), sequence: sequence)
        let data = try JSONEncoder().encode(rejoined)
        try data.write(to: participantRejoinedURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: participantRejoinedURL.path)
    }

    func waitForParticipantRejoined(timeout: TimeInterval = 90) throws {
        if relayIsConfigured {
            _ = try waitForRelayValue(kind: "participant-rejoined", timeout: timeout) { relayInt64($0) > 0 }
            return
        }
        let expectedRunID = try requiredRunID()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: participantRejoinedURL),
               let rejoined = try? JSONDecoder().decode(ProgressReady.self, from: data),
               rejoined.runID == expectedRunID, rejoined.sequence > 0 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("participant did not rejoin before timeout")
        throw RendezvousTestError.timedOut
    }

    func publishParticipantPlayback(_ state: String) throws {
        if relayIsConfigured {
            try relayPublish(kind: "participant-playback", value: state)
            return
        }
        let playback = PlaybackReady(runID: try requiredRunID(), state: state)
        let data = try JSONEncoder().encode(playback)
        try data.write(to: participantPlaybackURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: participantPlaybackURL.path)
    }

    func waitForParticipantPlayback(_ state: String, timeout: TimeInterval = 120) throws {
        if relayIsConfigured {
            _ = try waitForRelayValue(kind: "participant-playback", timeout: timeout) { ($0 as? String) == state }
            return
        }
        let expectedRunID = try requiredRunID()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: participantPlaybackURL),
               let playback = try? JSONDecoder().decode(PlaybackReady.self, from: data),
               playback.runID == expectedRunID, playback.state == state {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("participant did not observe playback state \(state) before timeout")
        throw RendezvousTestError.timedOut
    }

    @MainActor
    func openSharedBook(_ app: XCUIApplication) {
        let open = app.buttons["shared-reading-open-book"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        activate(open)
        XCTAssertTrue(app.buttons["reader.toolbar.toc"].waitForExistence(timeout: 90))
    }

    @MainActor
    func advanceSharedReader(_ app: XCUIApplication) {
        let nextPage = app.buttons["reader.next-page"]
        if nextPage.waitForExistence(timeout: 10) {
            activate(nextPage)
        } else {
            // iPhone uses Readium's native swipe navigation when the Catalyst
            // edge-arrow control is not present. No coordinate is hard-coded.
            app.swipeUp()
        }
    }

    @discardableResult
    @MainActor
    func waitForSharedProgress(_ app: XCUIApplication, atLeast sequence: Int64, timeout: TimeInterval = 90) -> Int64 {
        let progress = app.staticTexts["shared-reading-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = progress.value as? String,
               let received = Int64(value.replacingOccurrences(of: "sequence-", with: "")),
               received >= sequence {
                return received
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("shared progress did not reach sequence \(sequence)")
        return 0
    }

    @MainActor
    func assertSessionIsActive(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        let state = app.staticTexts["shared-reading-session-state"]
        XCTAssertTrue(state.waitForExistence(timeout: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.value as? String == "active" { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("shared-reading session did not become active")
    }

    /// Relaunches the app through its DEBUG reset path so a successful peer
    /// run does not leave the imported book or account-keyed caches behind.
    @MainActor
    func resetLocalState(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments.append("--rishi-e2e-reset")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        _ = waitForEmailField(app, timeout: 30)
        app.terminate()
        removeStagedFixture()
    }

    /// Restarts the peer without the destructive reset argument. This keeps
    /// the authenticated Keychain/local library state while forcing the
    /// sharing flow to rebuild its in-memory transport and coordinator.
    @MainActor
    func restartPreservingLocalState(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--rishi-e2e-reset" }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    @MainActor
    func openSession(_ app: XCUIApplication, token: String) {
        var components = URLComponents()
        components.scheme = "rishi"
        components.host = "sharing"
        components.path = "/session"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            XCTFail("invalid shared-reading token")
            return
        }
        app.open(url)
        let title = app.staticTexts["shared-reading-session-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 90))
    }

    @MainActor
    func rejoinActiveSession(_ app: XCUIApplication) {
        // Leaving a session changes membership to `left`; the supported
        // recovery path is the account-scoped Active reading list, which
        // obtains a fresh `/rejoin` admission ticket. Redeeming the original
        // invite again would test the wrong lifecycle and may race one-time
        // invite semantics.
        let activeSessions = app.buttons["shared-reading-active-sessions"]
        XCTAssertTrue(activeSessions.waitForExistence(timeout: 30))
        activate(activeSessions)
        let session = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'shared-reading-active-session-'")
        ).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 60))
        activate(session)
        XCTAssertTrue(app.staticTexts["shared-reading-session-title"].waitForExistence(timeout: 90))
    }

    private func writeInvite(_ token: String) throws {
        if relayIsConfigured {
            try relayPublish(kind: "invite", value: token)
            return
        }
        let value = Invite(runID: try requiredRunID(), inviteToken: token)
        let data = try JSONEncoder().encode(value)
        let url = rendezvousURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func waitForRelayValue(
        kind: String,
        timeout: TimeInterval,
        predicate: (Any?) -> Bool
    ) throws -> Any {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? relayRead(kind: kind), predicate(value) {
                return value as Any
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("relay event \(kind) was not observed before timeout")
        throw RendezvousTestError.timedOut
    }

    private func relayPublish(kind: String, value: Any) throws {
        let response = try relayRequest([
            "op": "publish",
            "secret": relaySecret ?? "",
            "runID": try requiredRunID(),
            "kind": kind,
            "value": value,
        ])
        guard response["ok"] as? Bool == true else {
            throw RendezvousTestError.relayUnavailable
        }
    }

    private func relayRead(kind: String) throws -> Any? {
        guard relayIsConfigured else { throw RendezvousTestError.relayUnavailable }
        let response = try relayRequest([
            "op": "read",
            "secret": relaySecret ?? "",
            "runID": try requiredRunID(),
            "kind": kind,
        ])
        guard response["ok"] as? Bool == true else {
            throw RendezvousTestError.relayUnavailable
        }
        guard let value = response["value"], !(value is NSNull) else { return nil }
        return value
    }

    private func relayRequest(_ request: [String: Any]) throws -> [String: Any] {
        #if canImport(Darwin)
        guard let port = relayPort,
              let host = ProcessInfo.processInfo.environment["RISHI_E2E_RENDEZVOUS_HOST"],
              host == "127.0.0.1" else {
            throw RendezvousTestError.relayUnavailable
        }
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw RendezvousTestError.relayUnavailable }
        defer { Darwin.close(socketFD) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr(host))
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw RendezvousTestError.relayUnavailable }

        var requestData = try JSONSerialization.data(withJSONObject: request)
        requestData.append(10)
        try requestData.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { throw RendezvousTestError.relayUnavailable }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(socketFD, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RendezvousTestError.relayUnavailable }
                offset += count
            }
        }

        var responseData = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(socketFD, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RendezvousTestError.relayUnavailable }
            responseData.append(bytes, count: count)
            guard responseData.count <= 1_048_576 else { throw RendezvousTestError.relayUnavailable }
            if responseData.contains(10) { break }
        }
        guard let newline = responseData.firstIndex(of: 10),
              let response = try JSONSerialization.jsonObject(with: responseData.prefix(upTo: newline)) as? [String: Any] else {
            throw RendezvousTestError.relayUnavailable
        }
        return response
        #else
        throw RendezvousTestError.relayUnavailable
        #endif
    }

    private func relayInt64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    private func stageFixture(at sourceURL: URL) throws -> URL {
        #if targetEnvironment(macCatalyst)
        // `homeDirectoryForCurrentUser` is unavailable to Catalyst in the
        // Xcode Beta SDK. NSHomeDirectory() resolves the same per-user
        // location and is available to both the Catalyst test runner and app.
        let groupURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(Self.appGroupIdentifier, isDirectory: true)
        #else
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw RendezvousTestError.relayUnavailable
        }
        #endif
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)

        let stagedURL = groupURL.appendingPathComponent(
            "\(Self.stagedFixtureName).\(sourceURL.pathExtension.lowercased())",
            isDirectory: false
        )
        // Clear only the harness-reserved fixture names so a previous run
        // using the other format cannot leave a real-book copy behind.
        for fileExtension in ["pdf", "epub"] {
            try? FileManager.default.removeItem(
                at: groupURL.appendingPathComponent(
                    "\(Self.stagedFixtureName).\(fileExtension)",
                    isDirectory: false
                )
            )
        }

        // The fixture usually lives on the same volume as the App Group.
        // Prefer a hard link so a large real book does not consume a second
        // copy of disk space; fall back to a copy for cross-volume inputs.
        let usedCopy: Bool
        do {
            try FileManager.default.linkItem(at: sourceURL, to: stagedURL)
            usedCopy = false
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
            usedCopy = true
        }
        if usedCopy {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        }
        return stagedURL
    }

    private func removeStagedFixture() {
        guard let stagedFixtureURL else { return }
        try? FileManager.default.removeItem(at: stagedFixtureURL)
        self.stagedFixtureURL = nil
    }

    static func inviteToken(from link: String) -> String? {
        guard let url = URL(string: link),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ((url.scheme == "rishi" && url.host == "sharing" && url.path == "/session")
               || (url.scheme == "https" && url.host == "rishi.fidexa.org" && url.path == "/sharing/session")),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
