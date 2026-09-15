import XCTest
@testable import CCSBarKit

/// The display preferences were four full-width switch rows written by hand,
/// covered by no test at all. They are a list now, so the things that actually
/// went wrong with them are checkable: copy that reads as one sentence with the
/// last word changed, and a preference that exists in storage with no way to
/// reach it.
final class PanelDisplayOptionsTests: XCTestCase {
    private var options: [PanelDisplayOption] { PanelDisplayOption.allCases }

    func testEveryStoredDisplayPreferenceHasARow() {
        // The failure this catches: adding a key to `FleetDisplay`, reading it
        // in the menu-bar label, and shipping with no way to turn it on.
        XCTAssertEqual(
            Set(options.map(\.key)),
            [
                FleetDisplay.disarmedKey,
                FleetDisplay.activeOnlyKey,
                FleetDisplay.remainingKey,
                FleetDisplay.barsKey,
            ],
            "a display preference exists in storage with no row, or a row points at a key nothing reads"
        )
    }

    func testEachOptionOwnsItsOwnKey() {
        XCTAssertEqual(Set(options.map(\.key)).count, options.count, "two rows write the same key")
    }

    func testTheLabelsReadAsFourDifferentThings() {
        XCTAssertEqual(Set(options.map(\.label)).count, options.count)
        // The original defect: "Menu bar shows disarmed mark", "…shows active
        // account", "…shows remaining", "…shows bars". Four labels sharing an
        // opening are four labels nobody reads past.
        let openings = options.map { $0.label.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(
            Set(openings).count, options.count,
            "two labels open with the same word — that is the repetition that made the block unreadable"
        )
    }

    func testLabelsFitAHalfWidthCell() {
        // The grid puts two per row on a 420pt panel. A leading checkbox costs
        // 19pt of the ~196pt cell, so about twenty-eight characters fit; the
        // budget is deliberately tighter than that. "Active account only"
        // rendered as "Active account o…" back when a 31pt switch trailed each
        // label, and a label that loses its last word is worse than one that
        // never had it.
        for option in options {
            XCTAssertLessThanOrEqual(
                option.label.count, 18,
                "\(option.label) will truncate in a half-width cell"
            )
        }
    }

    func testEveryOptionExplainsWhatHappens() {
        for option in options {
            XCTAssertFalse(option.help.isEmpty, "\(option.label) has no tooltip")
            XCTAssertNotEqual(option.help, option.label, "\(option.label) repeats itself instead of explaining")
            XCTAssertTrue(option.symbol.contains(where: { !$0.isWhitespace }), "\(option.label) has no glyph")
        }
    }

    func testOnlyTheDisarmedWarningStartsOn() {
        // A chain that will not rotate is a real degraded state; the other three
        // change how a healthy reading is drawn, and a default is a claim about
        // what most people want.
        XCTAssertEqual(options.filter(\.defaultsOn), [.disarmed])
    }

    func testTheRemainingPreferenceSaysItGovernsBothSurfaces() {
        // It is the only one that reaches past the menu bar into the account
        // rows; a tooltip that mentions only the menu bar would be a lie.
        let help = PanelDisplayOption.remaining.help.lowercased()
        XCTAssertTrue(help.contains("menu bar"), "does not say it changes the menu bar")
        XCTAssertTrue(help.contains("row"), "does not say it changes the account rows")
    }
}
