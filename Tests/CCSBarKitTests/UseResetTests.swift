import XCTest

@testable import CCSBarKit

/// The codex use-a-reset flow: argv shape, the menu's visibility rule, confirm
/// copy, stdout/stderr → message extraction, outcome routing, and the shared
/// captured-spawn helper — injected runners and decoded fixtures throughout,
/// no daemon and never a clauth spawn (the helper test drives `/bin/sh`).
final class UseResetTests: XCTestCase {
    /// A status snapshot with one codex profile (`credits` banked, nil = key
    /// absent) and one claude profile.
    private func status(codex name: String = "cx", credits: Int?) throws -> DaemonStatus {
        let banked = credits.map { "\"codex_reset_credits\":\($0)," } ?? ""
        return try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"cl",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[],
         "profiles":[
          {"name":"cl","active":true,"windows":[]},
          {"name":"\(name)","active":false,"provider":"openai","harness":"codex",\(banked)
           "windows":[{"label":"5h","utilization_pct":12.4},{"label":"7d","utilization_pct":88.6}]}
         ]}
        """.utf8))
    }

    private func profile(_ s: DaemonStatus, _ name: String) throws -> ProfileStatus {
        try XCTUnwrap(s.profiles.first { $0.name == name })
    }

    @MainActor
    private func model(credits: Int? = 2) throws -> StatusModel {
        // .down liveness: the success path then skips the socket refresh, so
        // the routing tests exercise pure state with zero IO.
        StatusModel(preview: try status(credits: credits), liveness: .down)
    }

    // MARK: - argv (the contract with `clauth use-reset`)

    func testUseResetArgsAlwaysPassYes() {
        XCTAssertEqual(DaemonClient.useResetArgs("cx"), ["use-reset", "cx", "--yes"],
                       "a non-TTY spawn without --yes is refused by clauth before any network call")
    }

    // MARK: - Visibility rule (the menu item)

    @MainActor
    func testMenuOffersAResetOnlyOnACodexRowWithOneBanked() throws {
        XCTAssertTrue(StatusModel.offersUseReset(try profile(try status(credits: 2), "cx")))
        XCTAssertTrue(StatusModel.offersUseReset(try profile(try status(credits: 1), "cx")))
        XCTAssertFalse(StatusModel.offersUseReset(try profile(try status(credits: 0), "cx")),
                       "zero banked: nothing to spend")
        XCTAssertFalse(StatusModel.offersUseReset(try profile(try status(credits: nil), "cx")),
                       "an absent count (older daemon, no poll yet) is not a count")
        XCTAssertFalse(StatusModel.offersUseReset(try profile(try status(credits: 2), "cl")),
                       "a claude row never offers it")
    }

    func testMenuTitleCarriesTheCount() {
        XCTAssertEqual(StatusModel.useResetMenuTitle(2), "Use a usage-limit reset… (2 left)")
    }

    // MARK: - Confirm copy (pure)

    func testPromptNamesTheAccountTheCountTheEffectAndFinality() {
        let many = StatusModel.useResetPrompt("cx", available: 3, fiveHourPct: 12.4, weeklyPct: 88.6)
        XCTAssertEqual(many,
                       "Use one of the 3 usage-limit resets on 'cx'? It reopens the 5-hour and weekly windows"
                       + " right away. Now: 5h 12% · weekly 89% used. A used reset can't be returned.")
        let one = StatusModel.useResetPrompt("cx", available: 1, fiveHourPct: nil, weeklyPct: 40)
        XCTAssertTrue(one.hasPrefix("Use the one usage-limit reset on 'cx'?"))
        XCTAssertTrue(one.contains("Now: weekly 40% used."), "a weekly-only account shows only what it has")
        let blind = StatusModel.useResetPrompt("cx", available: 2, fiveHourPct: nil, weeklyPct: nil)
        XCTAssertFalse(blind.contains("Now:"), "no figures known → no empty figure clause")
        XCTAssertTrue(blind.hasSuffix("A used reset can't be returned."))
    }

    @MainActor
    func testPendingPromptSelfHealsWhenTheTargetOrItsCountIsGone() throws {
        let armed = try model(credits: 2)
        armed.requestReset("cx")
        XCTAssertEqual(armed.pendingResetPrompt,
                       StatusModel.useResetPrompt("cx", available: 2, fiveHourPct: 12.4, weeklyPct: 88.6),
                       "the row's 5h and 7d figures land in their own slots")
        XCTAssertTrue(try XCTUnwrap(armed.pendingResetPrompt).contains("Now: 5h 12% · weekly 89% used."))

        let spent = try model(credits: 0)
        spent.pendingReset = "cx"
        XCTAssertNil(spent.pendingResetPrompt, "count dropped to 0 while the banner sat open")

        let gone = try model(credits: 2)
        gone.pendingReset = "renamed-away"
        XCTAssertNil(gone.pendingResetPrompt, "a banner must never outlive its target")
    }

    @MainActor
    func testAStaleArmIsDroppedNotJustHiddenSoItNeverReturnsUnprompted() throws {
        // Armed with 1 banked, then spent elsewhere (count 0): the arm must be
        // CLEARED, or a reset granted days later revives the banner by itself.
        let m = try model(credits: 1)
        m.requestReset("cx")
        m.dropStaleResetArm(against: try status(credits: 0))
        XCTAssertNil(m.pendingReset, "a spent target drops the arm")
        m.dropStaleResetArm(against: try status(credits: 1))
        XCTAssertNil(m.pendingReset, "the arm stays dropped")
        XCTAssertNil(m.pendingResetPrompt, "a new grant must not re-show a banner nobody re-armed")

        // Target gone, or no status at all (daemon down): same.
        let renamed = try model(credits: 2)
        renamed.requestReset("cx")
        renamed.dropStaleResetArm(against: try status(codex: "other", credits: 2))
        XCTAssertNil(renamed.pendingReset)
        let blind = try model(credits: 2)
        blind.requestReset("cx")
        blind.dropStaleResetArm(against: nil)
        XCTAssertNil(blind.pendingReset)

        // A still-valid target keeps its arm.
        let live = try model(credits: 2)
        live.requestReset("cx")
        live.dropStaleResetArm(against: try status(credits: 1))
        XCTAssertEqual(live.pendingReset, "cx")
    }

    // MARK: - stdout / stderr → message (pure)

    func testSummaryIsTheFirstStdoutLineWithoutThePrefix() {
        let stdout = """

        clauth: used a usage-limit reset on 'cx': 2 window(s) reopened, 0 left.
        the daemon shows the new usage at its next poll.

        """
        XCTAssertEqual(DaemonClient.useResetSummary(stdout: stdout),
                       "Used a usage-limit reset on 'cx': 2 window(s) reopened, 0 left.")
        XCTAssertEqual(DaemonClient.useResetSummary(stdout: "reset done\n"), "Reset done",
                       "an unprefixed line passes through")
        XCTAssertNil(DaemonClient.useResetSummary(stdout: " \n\n"))
    }

    func testFailureReasonDropsRustsErrorPrefixAndKeepsTheWholeRefusal() {
        XCTAssertEqual(
            DaemonClient.useResetFailureReason(
                stderr: "Error: nothing to reset on 'cx' right now; no reset was used\n", exitStatus: 1),
            "Nothing to reset on 'cx' right now; no reset was used")
        XCTAssertEqual(
            DaemonClient.useResetFailureReason(
                stderr: "Error: that reset is no longer available\nsee: clauth use-reset cx --list\n",
                exitStatus: 1),
            "That reset is no longer available — see: clauth use-reset cx --list")
        XCTAssertEqual(DaemonClient.useResetFailureReason(stderr: "\n", exitStatus: 2),
                       "clauth use-reset exited 2")
    }

    func testOutcomeClassification() {
        XCTAssertEqual(
            DaemonClient.useResetOutcome(
                name: "cx", status: 0, signaled: false,
                stdout: "clauth: used a usage-limit reset on 'cx'\n", stderr: ""),
            .used(summary: "Used a usage-limit reset on 'cx'"))
        XCTAssertEqual(
            DaemonClient.useResetOutcome(name: "cx", status: 1, signaled: false,
                                         stdout: "", stderr: "Error: no usage-limit resets available on 'cx'\n"),
            .failed("No usage-limit resets available on 'cx'"))
        // A signal death is the one outcome clauth never reported: it must not
        // read as "nothing happened", or a retry could spend a second reset.
        guard case .failed(let killed) = DaemonClient.useResetOutcome(
            name: "cx", status: 15, signaled: true, stdout: "", stderr: "")
        else { return XCTFail("a killed spawn is a failure") }
        XCTAssertTrue(killed.contains("may or may not"))
        XCTAssertTrue(killed.contains("clauth use-reset cx --list"))
    }

    // MARK: - Outcome routing (injected runner — no spawn)

    @MainActor
    func testConfirmSpendsOnceAndShowsClauthsSummary() async throws {
        let model = try model()
        let calls = Calls()
        var repolls: [String] = []
        model.requestReset("cx")
        model.confirmReset(
            runReset: { _ in
                calls.hit()
                return .used(summary: "Used a usage-limit reset on 'cx': 2 window(s) reopened, 1 left.")
            },
            repoll: { name, quiet in repolls.append("\(name):\(quiet ? "quiet" : "loud")") })
        XCTAssertNil(model.pendingReset, "confirm consumes the armed state")
        XCTAssertEqual(model.resetInFlight, "cx", "in-flight marks synchronously")
        XCTAssertTrue(model.useResetBlocked, "the menu item disables while the spawn runs")
        await settle(model)
        XCTAssertNil(model.resetInFlight)
        XCTAssertEqual(model.lastCommandNotice, "Used a usage-limit reset on 'cx': 2 window(s) reopened, 1 left.")
        XCTAssertNil(model.lastCommandError)
        XCTAssertEqual(calls.count, 1, "a reset is never retried")
        XCTAssertEqual(repolls, ["cx:loud"], "success forces a re-poll so the bars and count update now")
    }

    @MainActor
    func testSuccessWithoutASummaryStillSaysWhatHappened() async throws {
        let model = try model()
        model.requestReset("cx")
        model.confirmReset(runReset: { _ in .used(summary: nil) })
        await settle(model)
        XCTAssertEqual(model.lastCommandNotice, "Used a usage-limit reset on 'cx'.")
    }

    @MainActor
    func testFailureSurfacesClauthsWordsAndNoNotice() async throws {
        let model = try model()
        let calls = Calls()
        var repolls: [String] = []
        model.requestReset("cx")
        model.confirmReset(
            runReset: { _ in
                calls.hit()
                return .failed("That reset is no longer available")
            },
            repoll: { name, quiet in repolls.append("\(name):\(quiet ? "quiet" : "loud")") })
        await settle(model)
        XCTAssertEqual(model.lastCommandError, "That reset is no longer available")
        XCTAssertNil(model.lastCommandNotice)
        XCTAssertEqual(calls.count, 1, "a failure — possibly unconfirmed — is never retried")
        XCTAssertEqual(repolls, ["cx:quiet"],
                       "an unconfirmed outcome still re-polls the count, quietly so the error stays up")
    }

    @MainActor
    func testQuietRefreshNeverTouchesTheErrorBanner() async throws {
        let model = try model()
        model.showError("The reset may or may not have gone through.")
        for outcome in [CommandOutcome.unreachable, .daemonError(code: "x", message: "boom")] {
            let done = expectation(description: "refresh work ran")
            model.refreshQuietly("cx", work: { done.fulfill(); return outcome })
            await fulfillment(of: [done], timeout: 5)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(model.lastCommandError, "The reset may or may not have gone through.")
        }
    }

    @MainActor
    func testMissingBinaryPointsAtTheTerminalCommand() async throws {
        let model = try model()
        model.requestReset("cx")
        var repolls = 0
        model.confirmReset(runReset: { _ in .unreachable }, repoll: { _, _ in repolls += 1 })
        await settle(model)
        XCTAssertEqual(repolls, 0, "nothing ran, so there is nothing to re-poll")
        XCTAssertEqual(model.lastCommandError,
                       "Couldn't find the clauth binary. Run `clauth use-reset cx` in a terminal.")
    }

    @MainActor
    func testConfirmWaitsWhileALoginIsInFlight() throws {
        // A login rewrites the very profile use-reset reads. The armed state
        // stays armed so the user can confirm once the login settles.
        let model = try model()
        model.reauth("cx", codex: true, mode: .capture, run: { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .ok
        })
        XCTAssertTrue(model.useResetBlocked)
        model.requestReset("cx")
        model.confirmReset(runReset: { _ in
            XCTFail("a reset must never spawn while a login is in flight")
            return .unreachable
        })
        XCTAssertNil(model.resetInFlight)
        XCTAssertEqual(model.pendingReset, "cx")
    }

    @MainActor
    func testConfirmWaitsWhileADeleteIsInFlight() throws {
        let model = try model()
        model.deleteInFlight = "cx"
        XCTAssertTrue(model.useResetBlocked)
        model.requestReset("cx")
        model.confirmReset(runReset: { _ in
            XCTFail("a reset must never spawn while a delete is in flight")
            return .unreachable
        })
        XCTAssertNil(model.resetInFlight)
        XCTAssertEqual(model.pendingReset, "cx")
    }

    @MainActor
    func testStaleOrSpentTargetDropsTheArmWithoutSpawning() throws {
        for (m, target) in [(try model(credits: 0), "cx"), (try model(credits: 2), "gone")] {
            m.pendingReset = target
            m.confirmReset(runReset: { _ in
                XCTFail("nothing to spend — the spawn must not fire")
                return .unreachable
            })
            XCTAssertNil(m.pendingReset, "the armed state drops with its target")
            XCTAssertNil(m.resetInFlight)
        }
    }

    @MainActor
    func testCancelIsPureLocalState() throws {
        let model = try model()
        model.requestReset("cx")
        model.cancelReset()
        XCTAssertNil(model.pendingReset)
        XCTAssertNil(model.resetInFlight, "cancel never spawns anything")
    }

    // MARK: - Captured spawn (shared by delete and use-reset) — `/bin/sh`, never clauth

    func testCaptureReadsBothStreamsAndTheExitStatus() async {
        let result = await DaemonClient.runCapturing(
            "/bin/sh", ["-c", "printf 'out-line\\n'; printf 'err-line\\n' >&2; exit 3"],
            timeout: .seconds(10))
        XCTAssertEqual(result, .exited(status: 3, signaled: false,
                                       stdout: Data("out-line\n".utf8), stderr: Data("err-line\n".utf8)))
    }

    func testCaptureDoesNotDeadlockOnOutputPastThePipeBuffer() async {
        // 256 KiB on EACH stream — far past the 64 KiB pipe buffer. A drain that
        // waited for exit would park the child in write() until the watchdog.
        let result = await DaemonClient.runCapturing(
            "/bin/sh", ["-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2"],
            timeout: .seconds(10))
        guard case .exited(let status, let signaled, let out, let err) = result else {
            return XCTFail("the spawn must run")
        }
        XCTAssertEqual(status, 0)
        XCTAssertFalse(signaled, "finished on its own, not by the watchdog")
        XCTAssertEqual(out.count, 262_144)
        XCTAssertEqual(err.count, 262_144)
    }

    func testCaptureWatchdogKillsAWedgedChildAndSaysSo() async {
        let result = await DaemonClient.runCapturing(
            "/bin/sh", ["-c", "exec sleep 30"], timeout: .milliseconds(200))
        guard case .exited(_, let signaled, _, _) = result else {
            return XCTFail("the spawn must run")
        }
        XCTAssertTrue(signaled, "a watchdog kill must be distinguishable from a clean exit")
    }

    /// A thread-safe call counter for the `@Sendable` injected runner.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Yield the main actor until the reset Task has completed, or a cap elapses.
    @MainActor
    private func settle(_ model: StatusModel) async {
        for _ in 0..<200 where model.resetInFlight != nil {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
