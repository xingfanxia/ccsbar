import Foundation
import XCTest

@testable import CCSBarKit

/// The "Add account…" flow: the pure name validator (`AddAccountValidation.error`,
/// mirroring clauth's `validate_profile_name`), the model's injected-run add flow,
/// and the shared login failure copy. The spawn itself (`clauth login`) is never
/// invoked — operator constraint: no real browser login in tests — so coverage is
/// on the validation + state routing, where the user-facing behavior lives.
final class AddAccountTests: XCTestCase {
    // MARK: - Validator (pure — mirrors clauth's validate_profile_name)

    func testEmptyNameIsRejected() {
        XCTAssertEqual(AddAccountValidation.error("", existing: []), "Name can't be empty.")
    }

    func testWhitespaceOnlyIsRejectedAsEmpty() {
        // Trimmed before checking, so a spaces-only name reads as empty, not bad-char.
        let msg = AddAccountValidation.error("   ", existing: [])
        XCTAssertEqual(msg, "Name can't be empty.")
    }

    func testBadCharacterIsRejected() {
        // '/' is outside clauth's charset (ASCII alnum + - _ . @ +).
        let msg = AddAccountValidation.error("a/b", existing: [])
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("Use only letters"), "surfaces the charset rule")
    }

    func testNonAsciiLetterIsRejected() {
        // clauth uses is_ascii_alphanumeric, NOT the Unicode-wide isLetter — so an
        // accented/CJK letter must be rejected even though Swift's isLetter accepts it.
        XCTAssertNotNil(AddAccountValidation.error("café", existing: []))
        XCTAssertNotNil(AddAccountValidation.error("账号", existing: []))
    }

    func testLeadingDotIsRejected() {
        let msg = AddAccountValidation.error(".hidden", existing: [])
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("don't start with '.'"), "calls out the leading-dot rule")
    }

    func testCaseInsensitiveDuplicateRoutesToLogInAgain() {
        let msg = AddAccountValidation.error("XFX", existing: ["xfx", "cl-ax"])
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("already exists"), "flags the collision")
        XCTAssertTrue(msg!.contains("Log in again"), "routes the user to reauth instead")
    }

    func testValidNameWithFullCharsetIsAccepted() {
        // Exercises every allowed punctuation class in one name.
        XCTAssertNil(AddAccountValidation.error("a-b_c.d@e+f", existing: ["other"]))
    }

    func testDuplicateWithNoKnownProfilesIsAllowed() {
        // Daemon down / no snapshot → empty `existing` → collision check skipped so
        // clauth stays the authority (a real dup surfaces via the non-zero exit copy).
        XCTAssertNil(AddAccountValidation.error("xfx", existing: []))
    }

    // MARK: - Failure copy (pure — shared login message fn)

    func testAddSuccessHasNoErrorMessage() {
        XCTAssertNil(StatusModel.loginFailureMessage(.ok, name: "newacct"))
    }

    func testAddCLIFailureCarriesCauseAndTerminalFallback() {
        let msg = StatusModel.loginFailureMessage(
            .daemonError(code: "cli_failed", message: "clauth login exited 1"), name: "newacct")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("clauth login exited 1"), "carries the cause")
        XCTAssertTrue(msg!.contains("clauth login newacct"), "gives the terminal fallback")
    }

    func testAddMissingBinaryTellsUserToRunTheCLI() {
        let msg = StatusModel.loginFailureMessage(.unreachable, name: "newacct")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("clauth login newacct"))
    }

    // MARK: - Model flow (injected fake runner — no real login)

    @MainActor
    func testSuccessClearsInFlightAndInspectsNewcomer() async {
        // daemon down → the .ok path skips the socket refresh (would be a false
        // "unreachable"), so this exercises pure state routing with zero IO: the
        // in-flight flag clears, no error, and the newcomer becomes the inspected row.
        let model = StatusModel(preview: nil, liveness: .down)
        model.addAccount("newacct", run: { _ in .ok })
        XCTAssertEqual(model.reauthInFlight, "newacct", "marks in-flight synchronously")
        XCTAssertFalse(model.addingAccount, "the editor collapses on submit")
        await settle(model)
        XCTAssertNil(model.reauthInFlight, "a completed login clears the in-flight flag")
        XCTAssertNil(model.lastCommandError, "success surfaces no error banner")
        XCTAssertEqual(model.inspectedName, "newacct", "the newcomer is inspected so it's visible")
    }

    @MainActor
    func testFailureClearsInFlightAndShowsLoudError() async {
        let model = StatusModel(preview: nil, liveness: .down)
        model.addAccount("newacct", run: { _ in .daemonError(code: "cli_failed", message: "clauth login exited 1") })
        await settle(model)
        XCTAssertNil(model.reauthInFlight, "a failed login also clears the in-flight flag")
        XCTAssertNotNil(model.lastCommandError, "failure is loud")
        XCTAssertTrue(model.lastCommandError!.contains("clauth login newacct"),
                      "the error gives the terminal fallback command")
    }

    @MainActor
    func testGuardBlocksAnAddWhileALoginIsInFlight() async {
        let model = StatusModel(preview: nil, liveness: .down)
        let blocked: @Sendable (String) async -> CommandOutcome = { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000); return .ok
        }
        model.addAccount("first", run: blocked)
        XCTAssertEqual(model.reauthInFlight, "first", "first login marks in-flight synchronously")
        model.addAccount("second", run: blocked)
        XCTAssertEqual(model.reauthInFlight, "first", "a second login is dropped while one is in flight")
    }

    @MainActor
    func testCollisionIsPreBlockedBeforeSpawning() async throws {
        // A duplicate name must NOT reach the runner (clauth would silently reauth the
        // existing profile), so it surfaces the collision error and stays idle.
        let s = try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["xfx"],
         "profiles":[{"name":"xfx","active":true,
           "windows":[{"label":"5h","utilization_pct":10,"resets_at":"2099-01-01T00:00:00+00:00"}]}]}
        """.utf8))
        let model = StatusModel(preview: s, liveness: .ok)
        let boxed = SpawnFlag()
        let runner: @Sendable (String) async -> CommandOutcome = { _ in boxed.fired = true; return .ok }
        model.addAccount("XFX", run: runner) // case-insensitive dup of "xfx"
        await settle(model)
        XCTAssertFalse(boxed.fired, "a collision never spawns the login")
        XCTAssertNil(model.reauthInFlight, "no login goes in flight for a rejected name")
        XCTAssertNotNil(model.lastCommandError, "the collision is surfaced loudly")
        XCTAssertTrue(model.lastCommandError!.contains("Log in again"))
    }

    /// Yield the main actor until the add Task has run to completion (cleared the
    /// in-flight flag), or a generous cap elapses.
    @MainActor
    private func settle(_ model: StatusModel, cap: Int = 500) async {
        for _ in 0..<cap {
            if model.reauthInFlight == nil { return }
            await Task.yield()
        }
    }
}

/// A tiny reference box so a `@Sendable` runner closure can record whether it fired,
/// then be read back on the main actor after the flow settles.
private final class SpawnFlag: @unchecked Sendable {
    var fired = false
}
