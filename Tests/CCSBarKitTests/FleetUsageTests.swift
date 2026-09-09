import Foundation
import XCTest

@testable import CCSBarKit

/// FLEET-1 — `FleetUsage`, the number the menu-bar bars draw. Every exclusion is
/// pinned on its own, because each one is a decision about what "the pool" means
/// and a silent change to any of them would move the bars without moving a test.
final class FleetUsageTests: XCTestCase {
    /// One profile's wire JSON, so both helpers below build from one shape.
    private func profileJSON(
        _ name: String,
        harness: String = "claude",
        fiveH: Double? = nil,
        sevenD: Double? = nil,
        scoped: Double? = nil,
        tier: String? = "Max 5x",
        authStatus: String = "ok",
        provider: String = "anthropic",
        active: Bool = false
    ) -> String {
        var windows: [String] = []
        if let fiveH { windows.append("{\"label\":\"5h\",\"utilization_pct\":\(fiveH)}") }
        if let sevenD { windows.append("{\"label\":\"7d\",\"utilization_pct\":\(sevenD)}") }
        if let scoped { windows.append("{\"label\":\"7d fable\",\"utilization_pct\":\(scoped)}") }
        let tierJSON = tier.map { "\"\($0)\"" } ?? "null"
        return """
        {"name":"\(name)","active":\(active),"provider":"\(provider)","harness":"\(harness)",
         "tier":\(tierJSON),"auth_status":"\(authStatus)","windows":[\(windows.joined(separator: ","))]}
        """
    }

    private func profile(
        _ name: String,
        harness: String = "claude",
        fiveH: Double? = nil,
        sevenD: Double? = nil,
        scoped: Double? = nil,
        tier: String? = "Max 5x",
        authStatus: String = "ok",
        provider: String = "anthropic"
    ) throws -> ProfileStatus {
        try JSONDecoder().decode(
            ProfileStatus.self,
            from: Data(profileJSON(name, harness: harness, fiveH: fiveH, sevenD: sevenD,
                                   scoped: scoped, tier: tier, authStatus: authStatus,
                                   provider: provider).utf8)
        )
    }

    /// A daemon feed carrying exactly `profiles` — decoded from the wire, like
    /// the app does, so the fixture cannot drift from the real shape.
    /// The feed's stamp, and the `now` every ladder assertion passes with it —
    /// a fixed stamp against the real clock reads as a DEAD daemon (rung 1) and
    /// silently swallows whatever the test meant to check.
    private static let generatedAt = "2026-09-09T00:00:00+00:00"
    private var feedNow: Date { Theme.parseISO(Self.generatedAt) ?? Date() }

    private func status(
        _ profiles: [String],
        active: String? = nil,
        activeCodex: String? = nil
    ) throws -> DaemonStatus {
        let activeJSON = active.map { "\"\($0)\"" } ?? "null"
        let activeCodexJSON = activeCodex.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"generated_at":"\(Self.generatedAt)","active_profile":\(activeJSON),
         "active_codex_profile":\(activeCodexJSON),
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[],
         "profiles":[\(profiles.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // ── the figure itself ────────────────────────────────────────────────────

    func testPoolIsTheMeanOfEachAccountsWEEKLYWindow() throws {
        // The 5h readings are the louder pair and are deliberately ignored:
        // (10 + 60) / 2, not (80 + 60) / 2. A label that tracked the 5h window
        // swung 95 → 5 across one lunch break and could not be planned around.
        let fleet = FleetUsage.compute(try status([
            profileJSON("a", fiveH: 80, sevenD: 10),
            profileJSON("b", fiveH: 20, sevenD: 60),
        ]))
        XCTAssertEqual(try XCTUnwrap(fleet.claude), 35, accuracy: 0.001)
        XCTAssertEqual(fleet.claudeCount, 2, "the tooltip has to be able to say how many")
        XCTAssertNil(fleet.codex, "no codex account — an absent bar, never 0%")
        XCTAssertEqual(fleet.codexCount, 0)
    }

    func testFiveHourStandsInOnlyWhenThereIsNoWeeklyWindow() throws {
        let fleet = FleetUsage.compute(try status([profileJSON("a", fiveH: 42)]))
        XCTAssertEqual(
            try XCTUnwrap(fleet.claude), 42, accuracy: 0.001,
            "an account with only a 5h window still has a figure, not an absence"
        )
    }

    // ── pool or active account ───────────────────────────────────────────────

    func testActiveOnlyReadsEachHarnessOwnSlot() throws {
        let feed = try status(
            [
                profileJSON("cc-1", sevenD: 10, active: true),
                profileJSON("cc-2", sevenD: 90),
                profileJSON("cx-1", harness: "codex", sevenD: 20, provider: "openai"),
                profileJSON("cx-2", harness: "codex", sevenD: 80, provider: "openai", active: true),
            ],
            active: "cc-1",
            activeCodex: "cx-2"
        )
        let fleet = FleetUsage.compute(feed, activeOnly: true)
        // The two slots are independent — reading `active_profile` for codex
        // would report the claude account or nothing at all.
        XCTAssertEqual(try XCTUnwrap(fleet.claude), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fleet.codex), 80, accuracy: 0.001)
        XCTAssertEqual(fleet.claudeCount, 1)
        XCTAssertEqual(fleet.codexCount, 1)

        let pool = FleetUsage.compute(feed)
        XCTAssertEqual(try XCTUnwrap(pool.claude), 50, accuracy: 0.001, "the pool still averages")
    }

    func testActiveOnlyDrawsNothingForAHarnessWithNoSlot() throws {
        let fleet = FleetUsage.compute(
            try status([profileJSON("cc-1", sevenD: 10)], active: nil),
            activeOnly: true
        )
        XCTAssertNil(fleet.claude, "no slot pointer is an absence, never the first account")
    }

    func testActiveOnlyStillExcludesABrokenActiveAccount() throws {
        let fleet = FleetUsage.compute(
            try status([profileJSON("cc-1", sevenD: 10, authStatus: "broken")], active: "cc-1"),
            activeOnly: true
        )
        XCTAssertNil(fleet.claude, "a quota you cannot spend is not a reading")
    }

    func testSentenceDropsTheAccountCountWhenReadingOneNamedAccount() {
        let one = FleetUsage(claude: 40, claudeCount: 1, codex: nil, excluded: 3)
        XCTAssertEqual(
            FleetUsage.sentence(one, activeOnly: true),
            "Claude 40% used of the weekly window, active account only"
        )
        XCTAssertTrue(
            FleetUsage.sentence(one).contains("of 1 account"),
            "over a pool the count is the thing the figure cannot show"
        )
    }

    func testHarnessesAreMeasuredSeparately() throws {
        let fleet = FleetUsage.compute(try status([
            profileJSON("cc", fiveH: 90, sevenD: 90),
            profileJSON("cx", harness: "codex", sevenD: 10, provider: "openai"),
        ]))
        // Averaging the two pools together would report 50% and describe no real
        // limit: a spent Claude fleet says nothing about Codex quota.
        XCTAssertEqual(try XCTUnwrap(fleet.claude), 90, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fleet.codex), 10, accuracy: 0.001)
    }

    func testWeeklyOnlyAccountCounts() throws {
        // Codex ships weekly-only since 2026-07; the pool must still read it.
        let fleet = FleetUsage.compute(try status([
            profileJSON("cx", harness: "codex", sevenD: 44, provider: "openai")
        ]))
        XCTAssertEqual(try XCTUnwrap(fleet.codex), 44, accuracy: 0.001)
    }

    // ── what is excluded, and why ────────────────────────────────────────────

    func testScopedWindowNeverDecidesTheFigure() throws {
        // A spent Fable week caps ONE model, not the account — folding it in
        // would report a fleet as spent while every account still runs Sonnet.
        XCTAssertEqual(
            try XCTUnwrap(FleetUsage.spentPct(profile("a", fiveH: 12, sevenD: 20, scoped: 100))),
            20,
            accuracy: 0.001
        )
    }

    func testBrokenLoginIsNotCountedAsHeadroom() throws {
        XCTAssertNil(try FleetUsage.spentPct(profile("dead", fiveH: 0, authStatus: "broken")),
                     "a dead login's 0% is headroom nobody can spend")
    }

    func testLapsedPlanIsNotCountedAsHeadroom() throws {
        XCTAssertNil(try FleetUsage.spentPct(profile("gone", fiveH: 0, tier: "canceled")))
        XCTAssertNil(try FleetUsage.spentPct(profile("free", harness: "codex", sevenD: 0, tier: "free")))
    }

    func testThirdPartyAccountIsNotInThePool() throws {
        // A DeepSeek-style account reports a balance, not a percentage: no
        // unscoped window, so nothing to average.
        XCTAssertNil(try FleetUsage.spentPct(profile("ds", tier: nil, provider: "DeepSeek")))
    }

    func testEmptyPoolIsNilNotZero() throws {
        let fleet = FleetUsage.compute(try status([]))
        XCTAssertTrue(fleet.isEmpty)
        XCTAssertNil(fleet.claude)
        XCTAssertNil(fleet.codex, "0% would read as 'plenty left' on a pool that has nothing")
    }

    func testNoStatusIsEmpty() {
        XCTAssertTrue(FleetUsage.compute(nil).isEmpty)
    }

    func testOverHundredClampsToFull() throws {
        // The daemon can briefly report past the cap; the bar must not overflow.
        XCTAssertEqual(try XCTUnwrap(FleetUsage.spentPct(profile("a", fiveH: 120))), 100, accuracy: 0.001)
    }

    // ── the sentence the tooltip and VoiceOver share ─────────────────────────

    func testSentenceNamesWhatWasLeftOut() throws {
        // Seven accounts, three usable: the operator must not be left to wonder
        // why a fleet of one is being reported.
        let fleet = FleetUsage.compute(try status([
            profileJSON("ok", fiveH: 77),
            profileJSON("dead", fiveH: 0, authStatus: "broken"),
            profileJSON("lapsed", fiveH: 0, tier: "canceled"),
        ]))
        XCTAssertEqual(fleet.excluded, 2)
        XCTAssertTrue(
            FleetUsage.sentence(fleet).contains("2 more left out"),
            FleetUsage.sentence(fleet)
        )
    }

    func testSentenceNamesBothPoolsWithTheirCounts() {
        let text = FleetUsage.sentence(
            FleetUsage(claude: 43.4, claudeCount: 3, codex: 61.5, codexCount: 1)
        )
        XCTAssertTrue(
            text.hasPrefix("Claude 43% of 3 accounts · Codex 62% of 1 account"),
            text
        )
    }

    func testSentenceOmitsAnAbsentPool() {
        let text = FleetUsage.sentence(FleetUsage(claude: 10, claudeCount: 1, codex: nil))
        XCTAssertTrue(text.hasPrefix("Claude 10% of 1 account"), text)
        XCTAssertFalse(text.contains("Codex"), text)
    }

    func testSentenceSaysSoWhenThereIsNothingToMeasure() {
        XCTAssertEqual(FleetUsage.sentence(FleetUsage(claude: nil, codex: nil)),
                       "No account pool to measure yet")
    }

    // ── what the menu bar actually renders ──────────────────────────────────

    func testShownFlipsTheAxisAndRoundsAfterTheFlip() {
        XCTAssertEqual(FleetDisplay.shown(74.6, remaining: false), 75)
        XCTAssertEqual(FleetDisplay.shown(74.6, remaining: true), 25)
        // Rounding AFTER the flip: 99.6% spent has nothing left, and a rounded
        // -up 1 would promise headroom that is already gone.
        XCTAssertEqual(FleetDisplay.shown(99.6, remaining: true), 0)
        XCTAssertEqual(FleetDisplay.shown(120, remaining: false), 100, "clamped")
        XCTAssertEqual(FleetDisplay.shown(120, remaining: true), 0)
    }

    func testOneBarIsATemplateOfTheLineWidth() {
        let bar = FleetBarsImage.one(50)
        XCTAssertTrue(bar.isTemplate)
        XCTAssertEqual(bar.size.width, FleetBarsImage.width)
        XCTAssertEqual(bar.size.height, FleetBarsImage.barHeight)
    }

    @MainActor
    func testBothHarnessGlyphsResolve() {
        // The label leads each figure with its harness's brand mark; a missing
        // asset falls back to a letter, but neither should be missing today.
        XCTAssertNotNil(ProviderGlyph.image(for: .claude))
        XCTAssertNotNil(ProviderGlyph.image(for: .codex))
    }

    func testSentenceSaysWhichWayItIsCounting() {
        let fleet = FleetUsage(claude: 77, claudeCount: 1, codex: 95, codexCount: 2)
        XCTAssertTrue(FleetUsage.sentence(fleet, remaining: false).contains("% of 1 account · Codex 95% of 2 accounts used"),
                      FleetUsage.sentence(fleet, remaining: false))
        let left = FleetUsage.sentence(fleet, remaining: true)
        XCTAssertTrue(left.hasPrefix("Claude 23% of 1 account · Codex 5% of 2 accounts LEFT"), left)
    }

    // ── the ladder only swaps the glyph on the ordinary rungs ────────────────

    func testFleetBarsOnlyOnTheOrdinaryRungs() throws {
        let healthy = try status([profileJSON("a", fiveH: 42, sevenD: 10, active: true)], active: "a")
        let normal = MenuBarLabelLadder.spec(
            status: healthy, switchInFlight: false, rotationFlash: nil, now: feedNow
        )
        XCTAssertTrue(normal.showsFleetBars)

        let switching = MenuBarLabelLadder.spec(
            status: healthy, switchInFlight: true, rotationFlash: nil, now: feedNow
        )
        XCTAssertFalse(switching.showsFleetBars, "mid-switch the ellipsis is the state")

        let rotating = MenuBarLabelLadder.spec(
            status: healthy, switchInFlight: false, rotationFlash: "b", now: feedNow
        )
        XCTAssertFalse(rotating.showsFleetBars, "the rotation glyph is the heartbeat")

        // A daemon whose feed has frozen: the warning triangle must survive.
        let stale = try status([profileJSON("a", fiveH: 42, active: true)], active: "a")
        let dead = MenuBarLabelLadder.spec(
            status: stale, switchInFlight: false, rotationFlash: nil,
            now: feedNow.addingTimeInterval(3600)
        )
        XCTAssertFalse(dead.showsFleetBars, "a dead daemon must not look like a usage reading")
    }
}
