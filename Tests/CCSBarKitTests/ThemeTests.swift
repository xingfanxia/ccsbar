import XCTest

@testable import CCSBarKit

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

    // MARK: usageColor — absolute bands: green → amber at 70 → red at 90

    func testTheRampTurnsOnAbsolutePercentagesNotFractionsOfTheThreshold() {
        // The defect: a window with no chain line defaults to threshold 100, so
        // the old 0.8x rule only reached amber at 80 and red at 100 — a panel of
        // 70-to-85%-spent accounts read as all-green.
        XCTAssertEqual(Theme.usageColor(69, threshold: 95), Theme.success)
        XCTAssertEqual(Theme.usageColor(70, threshold: 95), Theme.warning)
        XCTAssertEqual(Theme.usageColor(89, threshold: 95), Theme.warning)
        XCTAssertEqual(Theme.usageColor(90, threshold: 95), Theme.danger)
        XCTAssertEqual(Theme.usageColor(120, threshold: 95), Theme.danger)
    }

    func testTheDefaultThresholdUsesTheSameBands() {
        // Most windows carry no chain line at all; they were the ones stuck green.
        XCTAssertEqual(Theme.usageColor(50), Theme.success)
        XCTAssertEqual(Theme.usageColor(78), Theme.warning, "78% spent is not a healthy account")
        XCTAssertEqual(Theme.usageColor(90), Theme.danger)
        XCTAssertEqual(Theme.usageColor(100), Theme.danger)
    }

    func testAnEarlyRotatingAccountGoesRedAtItsOwnLine() {
        // The threshold is a floor on urgency, never a ceiling: past its own
        // line the daemon is already acting, so calm-until-90 would hide it.
        XCTAssertEqual(Theme.usageColor(65, threshold: 60), Theme.danger)
        XCTAssertEqual(Theme.usageColor(50, threshold: 60), Theme.warning,
                       "amber keeps its share of wherever the red line is, so there is still a warning step")
        XCTAssertEqual(Theme.usageColor(20, threshold: 60), Theme.success)
        // And it never makes a bar CALMER than the absolute bands would.
        XCTAssertEqual(Theme.usageColor(95, threshold: 200), Theme.danger)
    }

    func testColorRolesAreDistinct() {
        // active (terracotta) ≠ act-verb (darkened) ≠ armed (sapphire); a healthy
        // bar must never render in the active hue.
        XCTAssertNotEqual(Theme.accent, Theme.actVerb)
        XCTAssertNotEqual(Theme.accent, Theme.sapphire)
        XCTAssertNotEqual(Theme.usageColor(10, threshold: 95), Theme.accent)
    }
}
