import XCTest

@testable import CCSBarKit

/// The profile-delete flow: argv shape, confirm copy, and outcome routing —
/// all with injected runners / decoded fixtures, no daemon and no spawn.
final class DeleteAccountTests: XCTestCase {
    // MARK: - argv (the contract with `clauth delete`)

    func testDeleteArgsUseYesAndNeverForce() {
        let args = DaemonClient.deleteArgs("xfx")
        XCTAssertEqual(args, ["delete", "xfx", "--yes"],
                       "a non-TTY spawn can never answer the CLI confirm — the panel's banner is the deliberate step")
        XCTAssertFalse(args.contains("--force"),
                       "a live `clauth start` session must keep refusing the delete; the UI never overrides it")
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
    func testConfirmDeleteRunsAndClearsInFlightOnSuccess() async {
        let model = StatusModel(preview: nil, liveness: .down)
        model.requestDelete("xfx")
        XCTAssertNotNil(model.pendingDelete)
        model.confirmDelete(runDelete: { _ in .ok })
        XCTAssertNil(model.pendingDelete, "confirm consumes the armed state")
        XCTAssertEqual(model.deleteInFlight, "xfx", "in-flight marks synchronously")
        await settleDelete(model)
        XCTAssertNil(model.deleteInFlight)
        XCTAssertNil(model.lastCommandError, "success surfaces no error banner")
    }

    @MainActor
    func testConfirmDeleteSurfacesTheCLIRefusalVerbatim() async {
        let model = StatusModel(preview: nil, liveness: .down)
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
    func testCancelDeleteIsPureLocalState() {
        let model = StatusModel(preview: nil, liveness: .down)
        model.requestDelete("xfx")
        model.cancelDelete()
        XCTAssertNil(model.pendingDelete)
        XCTAssertNil(model.deleteInFlight, "cancel never spawns anything")
    }

    @MainActor
    func testConfirmDeleteClearsInspectionOfTheDeletedProfile() async {
        let model = StatusModel(preview: nil, liveness: .down)
        model.inspectedName = "xfx"
        model.requestDelete("xfx")
        model.confirmDelete(runDelete: { _ in .ok })
        await settleDelete(model)
        XCTAssertNil(model.inspectedName, "an inspected card over a deleted profile is a dangling view")
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
