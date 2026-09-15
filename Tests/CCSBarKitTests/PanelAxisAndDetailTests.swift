import XCTest
@testable import CCSBarKit

/// The two panel rules AX's 2026-09-14 pass created, pinned the way this repo
/// pins view decisions: the decision moves out of the view into a pure function
/// and the function is tested. There is no render test for the panel, so a
/// decision left inside a `body` is a decision nothing can check.
final class PanelAxisAndDetailTests: XCTestCase {
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
