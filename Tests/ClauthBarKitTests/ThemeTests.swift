import XCTest

@testable import ClauthBarKit

/// Pure helpers that a "cleanup" could silently break — `parseISO`'s three-branch
/// microsecond fallback (if it regresses, `resetHint` returns nil and every reset
/// hint vanishes), `resetHintText`'s d/h/m boundaries, and `usageColor`'s bands.
final class ThemeTests: XCTestCase {
    // MARK: parseISO — the daemon writes `…+00:00`, sometimes with microseconds.

    func testParseISOPlainOffset() {
        // No fractional seconds, `+00:00` — the daemon's baseline format.
        let d = Theme.parseISO("2021-01-01T00:00:00+00:00")
        XCTAssertEqual(d?.timeIntervalSince1970, 1_609_459_200)
    }

    func testParseISOMicroseconds() throws {
        // 6 fractional digits: Foundation's `.withFractionalSeconds` parses it,
        // truncating to milliseconds (…​.519), so this must be non-nil and land on
        // the right second (downstream `resetHint` truncates the fraction anyway).
        let d = try XCTUnwrap(Theme.parseISO("2021-01-01T00:00:00.519183+00:00"))
        XCTAssertEqual(d.timeIntervalSince1970, 1_609_459_200, accuracy: 1.0)
    }

    func testParseISOZuluForm() {
        let d = Theme.parseISO("2021-01-01T00:00:00Z")
        XCTAssertEqual(d?.timeIntervalSince1970, 1_609_459_200)
    }

    func testParseISORejectsGarbage() {
        XCTAssertNil(Theme.parseISO("not-a-date"))
        XCTAssertNil(Theme.parseISO(""))
    }

    // MARK: resetHintText — coarsest-first, two units max, past → nil.

    func testResetHintPastIsNil() {
        XCTAssertNil(Theme.resetHintText(secondsRemaining: 0))
        XCTAssertNil(Theme.resetHintText(secondsRemaining: -60))
    }

    func testResetHintDaysAndHours() {
        // 5d 16h 30m → days+hours, minutes dropped.
        XCTAssertEqual(
            Theme.resetHintText(secondsRemaining: 5 * 86_400 + 16 * 3_600 + 30 * 60),
            "resets in 5d 16h"
        )
        // Exact days, zero hours → days only (no trailing " 0h").
        XCTAssertEqual(Theme.resetHintText(secondsRemaining: 3 * 86_400), "resets in 3d")
    }

    func testResetHintHoursAndMinutes() {
        XCTAssertEqual(Theme.resetHintText(secondsRemaining: 3 * 3_600 + 20 * 60), "resets in 3h 20m")
        XCTAssertEqual(Theme.resetHintText(secondsRemaining: 2 * 3_600), "resets in 2h")
    }

    func testResetHintMinutesOnly() {
        XCTAssertEqual(Theme.resetHintText(secondsRemaining: 12 * 60), "resets in 12m")
        // Under a minute but positive → "resets in 0m" (still not nil).
        XCTAssertEqual(Theme.resetHintText(secondsRemaining: 30), "resets in 0m")
    }

    // MARK: usageColor — healthy → warning at 80% of threshold → danger at threshold.

    func testUsageColorBands() {
        // threshold 95 → warning band starts at 0.8×95 = 76.
        XCTAssertEqual(Theme.usageColor(10, threshold: 95), Theme.accent)   // healthy
        XCTAssertEqual(Theme.usageColor(75, threshold: 95), Theme.accent)   // just under 76 → still healthy
        XCTAssertEqual(Theme.usageColor(76, threshold: 95), Theme.warning)  // at 0.8× → warning
        XCTAssertEqual(Theme.usageColor(94, threshold: 95), Theme.warning)  // just under threshold
        XCTAssertEqual(Theme.usageColor(95, threshold: 95), Theme.danger)   // at threshold
        XCTAssertEqual(Theme.usageColor(120, threshold: 95), Theme.danger)  // over
    }

    func testUsageColorDefaultThresholdIs100() {
        XCTAssertEqual(Theme.usageColor(50), Theme.accent)
        XCTAssertEqual(Theme.usageColor(85), Theme.warning) // ≥ 80
        XCTAssertEqual(Theme.usageColor(100), Theme.danger)
    }
}
