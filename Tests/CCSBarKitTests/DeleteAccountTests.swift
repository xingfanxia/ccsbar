import XCTest

@testable import CCSBarKit

/// The profile-delete flow: argv shape, confirm copy, stderr→reason
/// extraction, and outcome routing — all with injected runners / decoded
/// fixtures, no daemon and no spawn.
final class DeleteAccountTests: XCTestCase {
    /// A status snapshot carrying one profile, so the stale-target guard sees
    /// the delete's target as real.
    private func status(withProfile name: String) throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":null,
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[],
         "profiles":[{"name":"\(name)","active":false,"windows":[]}]}
        """.utf8))
    }

    @MainActor
    private func model(withProfile name: String) throws -> StatusModel {
        // .down liveness: the .ok path then skips the socket refresh, so the
        // routing tests exercise pure state with zero IO.
        StatusModel(preview: try status(withProfile: name), liveness: .down)
    }

    // MARK: - argv (the contract with `clauth delete`)

    func testDeleteArgsUseYesAndNeverForce() {
        let args = DaemonClient.deleteArgs("xfx")
        XCTAssertEqual(args, ["delete", "xfx", "--yes"],
                       "a non-TTY spawn can never answer the CLI confirm — the panel's banner is the deliberate step")
        XCTAssertFalse(args.contains("--force"),
                       "a live `clauth start` session must keep refusing the delete; the UI never overrides it")
    }

    // MARK: - stderr → reason (pure)

    func testFailureReasonKeepsTheWholeMultiLineRefusal() {
        // clauth's `resolve_or_bail` emits TWO lines; dropping either loses the
        // failure or the hint. (The first cut of this code took `.last` and the
        // banner showed a bare profile list with no error at all.)
        let reason = DaemonClient.deleteFailureReason(
            stderr: "Error: profile 'xfx' not found\navailable: a, b, c\n", exitStatus: 1)
        XCTAssertEqual(reason, "Error: profile 'xfx' not found — available: a, b, c")
    }

    func testFailureReasonPassesASingleLineVerbatim() {
        let reason = DaemonClient.deleteFailureReason(
            stderr: "Error: 'xfx' is running a session\n", exitStatus: 1)
        XCTAssertEqual(reason, "Error: 'xfx' is running a session")
    }

    func testFailureReasonFallsBackToTheExitStatus() {
        XCTAssertEqual(DaemonClient.deleteFailureReason(stderr: "  \n\n", exitStatus: 3),
                       "clauth delete exited 3")
    }

    // MARK: - Confirm copy (pure)

    func testDeletePromptNamesEveryConsequence() {
        let plain = StatusModel.deletePrompt("xfx", active: false, inChain: false)
        XCTAssertTrue(plain.contains("'xfx'"))
        XCTAssertTrue(plain.contains("credentials"), "the destructive half is the point of the confirm")
        XCTAssertFalse(plain.contains("ACTIVE"))
        XCTAssertFalse(plain.contains("chain"))

        let active = StatusModel.deletePrompt("xfx", active: true, inChain: false)
        XCTAssertTrue(active.contains("ACTIVE"), "deleting the active account clears the live login — say so")

        let chained = StatusModel.deletePrompt("xfx", active: false, inChain: true)
        XCTAssertTrue(chained.contains("chain"), "a chain member's removal changes what auto-switch can do")
    }

    // MARK: - Outcome routing (injected runner — no spawn)

    @MainActor
    func testConfirmDeleteRunsAndClearsInFlightOnSuccess() async throws {
        let model = try model(withProfile: "xfx")
        model.requestDelete("xfx")
        XCTAssertNotNil(model.pendingDeletePrompt)
        model.confirmDelete(runDelete: { _ in .ok })
        XCTAssertNil(model.pendingDelete, "confirm consumes the armed state")
        XCTAssertEqual(model.deleteInFlight, "xfx", "in-flight marks synchronously")
        await settleDelete(model)
        XCTAssertNil(model.deleteInFlight)
        XCTAssertNil(model.lastCommandError, "success surfaces no error banner")
    }

    @MainActor
    func testConfirmDeleteSurfacesTheCLIRefusalVerbatim() async throws {
        let model = try model(withProfile: "xfx")
        model.requestDelete("xfx")
        model.confirmDelete(runDelete: { _ in
            .daemonError(code: "cli_failed", message: "refusing to delete 'xfx': a live session is running")
        })
        await settleDelete(model)
        XCTAssertNil(model.deleteInFlight)
        XCTAssertEqual(model.lastCommandError,
                       "refusing to delete 'xfx': a live session is running",
                       "clauth's own refusal is the error copy — not a bare exit code")
    }

    @MainActor
    func testCancelDeleteIsPureLocalState() throws {
        let model = try model(withProfile: "xfx")
        model.requestDelete("xfx")
        model.cancelDelete()
        XCTAssertNil(model.pendingDelete)
        XCTAssertNil(model.deleteInFlight, "cancel never spawns anything")
    }

    @MainActor
    func testConfirmDeleteClearsInspectionOfTheDeletedProfile() async throws {
        let model = try model(withProfile: "xfx")
        model.inspectedName = "xfx"
        model.requestDelete("xfx")
        model.confirmDelete(runDelete: { _ in .ok })
        await settleDelete(model)
        XCTAssertNil(model.inspectedName, "an inspected card over a deleted profile is a dangling view")
    }

    // MARK: - Guards (mutual exclusion + stale target)

    @MainActor
    func testConfirmDeleteRefusesWhileALoginIsInFlight() throws {
        // `clauth login` runs OUTSIDE the state flock for its whole browser
        // wait; a concurrent delete races the profile directory. The armed
        // state stays armed — the user can confirm once the login settles.
        let model = try model(withProfile: "xfx")
        model.reauth("xfx", run: { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .ok
        })
        model.requestDelete("xfx")
        model.confirmDelete(runDelete: { _ in
            XCTFail("a delete must never spawn while a login is in flight")
            return .ok
        })
        XCTAssertNil(model.deleteInFlight)
        XCTAssertEqual(model.pendingDelete, "xfx", "the armed confirm survives for after the login")
    }

    @MainActor
    func testStaleDeleteTargetSelfHeals() throws {
        // The target vanished while the banner sat open (renamed / removed by
        // another actor): the prompt reads nil so the banner drops, and a
        // confirm no-ops instead of firing a guaranteed refusal.
        let model = try model(withProfile: "other")
        model.pendingDelete = "xfx"
        XCTAssertNil(model.pendingDeletePrompt, "a danger banner must never outlive its target")
        model.confirmDelete(runDelete: { _ in
            XCTFail("nothing to delete — the spawn must not fire")
            return .ok
        })
        XCTAssertNil(model.pendingDelete, "the armed state drops with the target")
        XCTAssertNil(model.deleteInFlight)
    }

    /// Yield the main actor until the delete Task has completed, or a cap elapses.
    @MainActor
    private func settleDelete(_ model: StatusModel) async {
        for _ in 0..<200 where model.deleteInFlight != nil {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
