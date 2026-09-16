import XCTest
@testable import CCSBarKit

/// The two panel rules AX's 2026-09-14 pass created, pinned the way this repo
/// pins view decisions: the decision moves out of the view into a pure function
/// and the function is tested. There is no render test for the panel, so a
/// decision left inside a `body` is a decision nothing can check.
final class PanelAxisAndDetailTests: XCTestCase {
    // MARK: - A flipped figure says so

    func testOnlyTheFlippedAxisIsWorded() {
        // The defect this closes: "7d 0%" is a true reading of an exhausted
        // account in remaining mode and of an untouched one in spent mode, and
        // the bar cannot separate them — at both ends of the axis the two modes
        // draw the same shape (AX, 2026-09-16, three codex rows at 0%).
        XCTAssertEqual(UsageFigure.parts(pct: 100, remaining: true).figure, "0%")
        XCTAssertEqual(UsageFigure.parts(pct: 100, remaining: true).suffix, "left")
        XCTAssertNil(
            UsageFigure.parts(pct: 0, remaining: false).suffix,
            "the unmarked number is the convention every other surface reports on; wording it too would print chrome over the default"
        )
        XCTAssertEqual(UsageFigure.parts(pct: 0, remaining: false).figure, "0%")
    }

    func testAGroupStatesItsAxisOnceAndTheMinisInheritIt() {
        // Three "left"s in one account row read as noise, and the extra text
        // column ate the flexible bars beside it — a 7d bar and a Fable bar
        // stopped being the same length for the same number.
        let hero = UsageFigure(pct: 42, remaining: true)
        let mini = UsageFigure(pct: 42, remaining: true, wordsAxis: false)
        XCTAssertTrue(hero.wordsAxis)
        XCTAssertFalse(mini.wordsAxis)
        XCTAssertEqual(
            UsageFigure.parts(pct: 42, remaining: true).suffix, "left",
            "the leading figure of a group still carries the word"
        )
    }

    @MainActor
    func testTheForecastFigureNamesItsAxisWhenTheRowsDisagree() {
        // It stays on the spent axis because the sentence above it quotes the
        // rotation threshold ("would switch at 95%"), and a threshold is a
        // spend value — so in remaining mode it is the odd figure out.
        let status = try! JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[],
         "profiles":[{"name":"a","active":true,"tier":"Max 20x",
                      "windows":[{"label":"5h","utilization_pct":42.0}]}]}
        """.utf8))
        let model = StatusModel(preview: status, liveness: .ok)
        XCTAssertTrue(model.livenessStamp(remaining: false).contains("now 42%"))
        XCTAssertFalse(
            model.livenessStamp(remaining: false).contains("used"),
            "the default axis needs no word — every figure on the panel agrees with it"
        )
        XCTAssertTrue(
            model.livenessStamp(remaining: true).contains("now 42% used"),
            "it stays on the spent axis beside the threshold, so it has to say so once the rows flip"
        )
    }

    func testAMissingReadingIsADashAndNeverAZero() {
        XCTAssertEqual(UsageFigure.parts(pct: nil, remaining: true).figure, "—")
        XCTAssertNil(
            UsageFigure.parts(pct: nil, remaining: true).suffix,
            "'— left' reads as a broken sentence; a missing window has no axis"
        )
    }

    func testTheWordedFigureAndTheSpokenOneAgree() {
        // One spelling of the axis word, or the Overview card tells VoiceOver
        // "percent used" while showing what is left — which it did.
        XCTAssertEqual(FleetDisplay.axisWord(remaining: true), "left")
        XCTAssertEqual(FleetDisplay.axisWord(remaining: false), "used")
        XCTAssertEqual(
            UsageFigure.parts(pct: 42, remaining: true).suffix,
            FleetDisplay.axisWord(remaining: true)
        )
    }

    // MARK: - The account rows read the same axis as the menu bar

    func testTheBarFillsOnTheAxisTheNumberBesideItIsReading() {
        let used = UsageBar.geometry(pct: 94, threshold: nil, remaining: false)
        XCTAssertEqual(used.fill, 94)
        let left = UsageBar.geometry(pct: 94, threshold: nil, remaining: true)
        XCTAssertEqual(
            left.fill, 6,
            "the bar still fills by spend while the number counts down — the exact defect the menu-bar label already had"
        )
    }

    func testTheNumberAndTheBarComeFromOneHelper() {
        // Not a tautology: it fails the moment either surface grows its own
        // spelling of the flip, which is how the menu bar and the rows would
        // drift apart.
        for pct in [0.0, 1.0, 37.4, 94.0, 99.6, 100.0] {
            for remaining in [false, true] {
                XCTAssertEqual(
                    UsageBar.geometry(pct: pct, threshold: nil, remaining: remaining).fill,
                    FleetDisplay.value(pct, remaining: remaining),
                    "bar fill diverged from the shared axis helper at \(pct), remaining=\(remaining)"
                )
            }
        }
    }

    func testTheThresholdTickMirrorsWithTheBar() {
        // The tick marks the auto-switch threshold, a point on the SPENT axis.
        // Left unmirrored it keeps pointing at 95% of the bar while the bar now
        // measures headroom, i.e. it silently marks 5% remaining as the line.
        let used = UsageBar.geometry(pct: 40, threshold: 95, remaining: false)
        XCTAssertEqual(used.tick, 95)
        let left = UsageBar.geometry(pct: 40, threshold: 95, remaining: true)
        XCTAssertEqual(left.tick, 5, "the tick did not follow the bar")
    }

    func testNoThresholdStaysAbsentOnBothAxes() {
        XCTAssertNil(UsageBar.geometry(pct: 40, threshold: nil, remaining: false).tick)
        XCTAssertNil(UsageBar.geometry(pct: 40, threshold: nil, remaining: true).tick)
    }

    // MARK: - The detail card stops repeating the row above it

    func testTheActiveHealthyAccountGetsNoVerb() {
        XCTAssertFalse(
            DetailCard.showsVerb(active: true, authBroken: false, canReauth: true),
            "a disabled Active account button plus 'pick another account above' was the loudest half of the duplicate"
        )
    }

    func testAnInactiveAccountKeepsItsSwitchVerb() {
        XCTAssertTrue(DetailCard.showsVerb(active: false, authBroken: false, canReauth: true))
    }

    func testABrokenLoginOutranksBeingActive() {
        // The one account you cannot switch away from must still show its fix.
        XCTAssertTrue(DetailCard.showsVerb(active: true, authBroken: true, canReauth: true))
    }

    func testAThirdPartyAccountHasNoLoginToRenew() {
        // The daemon never marks an api-key profile auth_broken, but the rule
        // and the context-menu item have to agree about who can re-login.
        XCTAssertFalse(DetailCard.showsVerb(active: true, authBroken: true, canReauth: false))
        XCTAssertTrue(
            DetailCard.showsVerb(active: false, authBroken: true, canReauth: false),
            "it is still a switch target"
        )
    }

    func testTheCardIsEmptyWhenEveryThingItCouldSayIsAlreadyInTheRow() {
        XCTAssertTrue(
            DetailCard.isEmpty(
                hasVerb: false, hasTokenLine: false, hasChainLine: false,
                hasLiveSession: false, hasThirdPartyHost: false
            ),
            "an active account with nothing unique must draw no card AND no divider"
        )
    }

    func testAnySingleUniqueFactKeepsTheCard() {
        let facts: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("verb", true, false, false, false, false),
            ("token horizon", false, true, false, false, false),
            ("chain membership", false, false, true, false, false),
            ("live session", false, false, false, true, false),
            ("third-party host", false, false, false, false, true),
        ]
        for (name, verb, token, chain, live, host) in facts {
            XCTAssertFalse(
                DetailCard.isEmpty(
                    hasVerb: verb, hasTokenLine: token, hasChainLine: chain,
                    hasLiveSession: live, hasThirdPartyHost: host
                ),
                "\(name) is not in the account row, so it must keep the card alive"
            )
        }
    }
}
