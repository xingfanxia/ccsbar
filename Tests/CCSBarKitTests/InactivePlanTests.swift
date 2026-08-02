import XCTest

@testable import CCSBarKit

/// The inactive-plan collapse: tier classification, the never-hide-the-active
/// exclusion, and the `rolling_token` / legacy `session_feed` decode alias.
final class InactivePlanTests: XCTestCase {
    private func profile(
        _ name: String = "acct", tier: String?, active: Bool = false, extra: String = ""
    ) throws -> ProfileStatus {
        let tierJSON = tier.map { "\"tier\":\"\($0)\"," } ?? ""
        let json = """
        {"name":"\(name)","active":\(active),\(tierJSON)"provider":"anthropic","windows":[]\(extra)}
        """
        return try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
    }

    // MARK: - Tier classification

    func testCanceledAndFreeTiersReadInactive() throws {
        // The claude side labels a canceled subscription's tier "canceled"
        // (clauth profile_json: /profile subscription_status); a lapsed codex
        // account reads "free". Both spellings of cancelled, case-insensitive.
        XCTAssertTrue(try profile(tier: "canceled").planInactive)
        XCTAssertTrue(try profile(tier: "Cancelled").planInactive)
        XCTAssertTrue(try profile(tier: "free").planInactive)
    }

    func testRealTiersAndAbsentTierStayCurrent() throws {
        XCTAssertFalse(try profile(tier: "Max 20x").planInactive)
        XCTAssertFalse(try profile(tier: "pro").planInactive)
        XCTAssertFalse(try profile(tier: nil).planInactive,
                       "no tier read yet is not evidence of a dead plan")
    }

    // MARK: - The partition (never hide the active account)

    func testPartitionNeverCollapsesTheActiveAccount() throws {
        let profiles = [
            try profile("main", tier: "Max 20x", active: true),
            try profile("lapsed", tier: "canceled"),
            try profile("backup", tier: "Max 20x"),
            try profile("active-but-lapsed", tier: "free", active: true),
        ]
        let (current, inactive) = AccountsSection.partition(profiles)
        XCTAssertEqual(inactive.map(\.name), ["lapsed"],
                       "only a NON-active dead plan collapses")
        XCTAssertEqual(current.map(\.name), ["main", "backup", "active-but-lapsed"],
                       "the active account never hides, whatever its plan is worth")
    }

    func testPartitionIsIdentityWhenNothingIsInactive() throws {
        let profiles = [
            try profile("a", tier: "Max 20x"),
            try profile("b", tier: nil),
        ]
        let (current, inactive) = AccountsSection.partition(profiles)
        XCTAssertEqual(current.map(\.name), ["a", "b"])
        XCTAssertTrue(inactive.isEmpty)
    }

    // MARK: - rolling_token decode (both sides of the daemon rename)

    func testRollingTokenDecodesFromEitherSpelling() throws {
        // The renamed key (clauth ≥ #59)…
        XCTAssertTrue(try profile(tier: nil, extra: ",\"rolling_token\":true").rollingToken)
        // …the fork's pre-rename key…
        XCTAssertTrue(try profile(tier: nil, extra: ",\"session_feed\":true").rollingToken)
        // …absent = false (older daemons)…
        XCTAssertFalse(try profile(tier: nil).rollingToken)
        // …and when both appear, the CURRENT key wins — the daemon that writes
        // both is mid-transition and rolling_token is its own truth.
        XCTAssertFalse(
            try profile(tier: nil, extra: ",\"rolling_token\":false,\"session_feed\":true")
                .rollingToken)
    }
}
