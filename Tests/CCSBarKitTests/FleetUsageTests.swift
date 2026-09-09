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

    private func status(_ profiles: [String], active: String? = nil) throws -> DaemonStatus {
        let activeJSON = active.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"generated_at":"\(Self.generatedAt)","active_profile":\(activeJSON),
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[],
         "profiles":[\(profiles.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // ── the figure itself ────────────────────────────────────────────────────

    func testPoolIsTheMeanOfEachAccountsWorseWindow() throws {
        // 5h beats weekly on one, weekly beats 5h on the other: (80 + 60) / 2.
        let fleet = FleetUsage.compute(try status([
            profileJSON("a", fiveH: 80, sevenD: 10),
            profileJSON("b", fiveH: 20, sevenD: 60),
        ]))
        XCTAssertEqual(try XCTUnwrap(fleet.claude), 70, accuracy: 0.001)
        XCTAssertEqual(fleet.claudeCount, 2, "the tooltip has to be able to say how many")
        XCTAssertNil(fleet.codex, "no codex account — an absent bar, never 0%")
        XCTAssertEqual(fleet.codexCount, 0)
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

    /// The bars are a DRAWN template image, not SwiftUI shapes: a first cut
    /// used `Capsule().fill(…)` and rendered as nothing in the menu bar while
    /// every test passed, because `MenuBarExtra` flattens its label to an
    /// image and only Text and Image survive. This pins the drawing.
    func testBarsAreADrawnTemplateImageSizedToThePoolsPresent() throws {
        let both = try XCTUnwrap(FleetBarsImage.make(FleetUsage(claude: 50, codex: 20)))
        XCTAssertTrue(both.isTemplate, "a non-template image ignores the menu bar's appearance")
        XCTAssertEqual(both.size.width, FleetBarsImage.width)
        XCTAssertEqual(both.size.height, FleetBarsImage.barHeight * 2 + FleetBarsImage.gap)

        // One pool present → ONE bar, not an empty second track: a full-width
        // empty track reads as "nothing used", the opposite of "nothing known".
        let one = try XCTUnwrap(FleetBarsImage.make(FleetUsage(claude: 50, codex: nil)))
        XCTAssertEqual(one.size.height, FleetBarsImage.barHeight)

        XCTAssertNil(FleetBarsImage.make(FleetUsage(claude: nil, codex: nil)))
    }

    func testNumbersFollowTheBarOrderAndRound() {
        XCTAssertEqual(FleetBarsImage.numbers(FleetUsage(claude: 74.6, codex: 94.5)), "75·95")
        XCTAssertEqual(FleetBarsImage.numbers(FleetUsage(claude: 10, codex: nil)), "10")
        XCTAssertEqual(FleetBarsImage.numbers(FleetUsage(claude: nil, codex: nil)), "")
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
