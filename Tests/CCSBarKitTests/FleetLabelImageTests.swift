import AppKit
import XCTest
@testable import CCSBarKit

/// FLEET-1 regression: the menu-bar label must carry BOTH harness figures.
///
/// Two shipped builds looked right in code and passed every unit test while the
/// menu bar showed only part of the label — first the bars rendered as nothing,
/// then the second harness group vanished ("我同时只能看到一个 icon啊", AX
/// 2026-09-09). Both were `MenuBarExtra` dropping sibling views. Asserting on
/// the model could not catch either, so these tests assert on the PIXELS of the
/// composited image the label actually hands to the status item.
@MainActor
final class FleetLabelImageTests: XCTestCase {
    /// Columns of the rendered image that contain any ink, as fractions of the
    /// width. Reading the drawn output is the only check that would have failed
    /// on the builds that shipped broken.
    private func inkedColumns(_ image: NSImage) throws -> [Bool] {
        guard let rep = image.representations.first as? NSBitmapImageRep
            ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
        else { throw XCTSkip("no raster backing in this environment") }
        return (0..<rep.pixelsWide).map { x in
            (0..<rep.pixelsHigh).contains { y in
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
            }
        }
    }

    private var both: FleetUsage {
        FleetUsage(claude: 94, claudeCount: 1, codex: 98.5, codexCount: 2)
    }

    func testTwoHarnessesDrawInkInBothHalves() throws {
        guard let image = FleetLabelImage.make(
            both, remaining: false, showsBars: false, trailing: nil
        ) else { return XCTFail("a two-harness fleet must produce a label") }
        let columns = try inkedColumns(image)
        let half = columns.count / 2
        XCTAssertTrue(
            columns[..<half].contains(true),
            "the first harness figure drew nothing"
        )
        XCTAssertTrue(
            columns[half...].contains(true),
            "the second harness figure drew nothing — this is the one-icon bug"
        )
    }

    func testTwoHarnessesAreWiderThanOne() {
        let one = FleetLabelImage.make(
            FleetUsage(claude: 94, claudeCount: 1, codex: nil),
            remaining: false, showsBars: false, trailing: nil
        )
        let two = FleetLabelImage.make(both, remaining: false, showsBars: false, trailing: nil)
        guard let one, let two else { return XCTFail("both fleets must produce a label") }
        XCTAssertGreaterThan(
            two.size.width, one.size.width,
            "the codex figure has to take room; equal widths mean it was never drawn"
        )
    }

    func testBarsAndTrailingMarkEachAddWidth() {
        let plain = FleetLabelImage.make(both, remaining: false, showsBars: false, trailing: nil)
        let barred = FleetLabelImage.make(both, remaining: false, showsBars: true, trailing: nil)
        let marked = FleetLabelImage.make(
            both, remaining: false, showsBars: false, trailing: "bolt.slash"
        )
        guard let plain, let barred, let marked else { return XCTFail("labels must render") }
        XCTAssertGreaterThan(barred.size.width, plain.size.width, "bars must occupy width")
        XCTAssertGreaterThan(
            marked.size.width, plain.size.width,
            "the ladder's trailing mark must be composited in, not dropped as a sibling"
        )
    }

    func testEmptyFleetHasNoLabelSoTheLadderKeepsItsOwnGlyph() {
        XCTAssertNil(
            FleetLabelImage.make(
                FleetUsage(claude: nil, codex: nil),
                remaining: false, showsBars: false, trailing: nil
            ),
            "with no countable account the ladder's glyph and text must show instead"
        )
    }

    func testTheLabelIsATemplateSoTheMenuBarCanTintIt() {
        let image = FleetLabelImage.make(both, remaining: false, showsBars: false, trailing: nil)
        XCTAssertEqual(image?.isTemplate, true)
    }

    func testRemainingFlipsBothFiguresNotJustTheFirst() {
        // 94 used → 6 left is one digit narrower; 98.5 → 2 likewise. If only the
        // first figure flipped the widths would not both shrink.
        let used = FleetLabelImage.make(both, remaining: false, showsBars: false, trailing: nil)
        let left = FleetLabelImage.make(both, remaining: true, showsBars: false, trailing: nil)
        guard let used, let left else { return XCTFail("labels must render") }
        XCTAssertLessThan(left.size.width, used.size.width)
    }

    func testEveryCountableHarnessGetsItsOwnFigure() {
        XCTAssertEqual(
            FleetLabelImage.figures(both, remaining: false).map(\.harness),
            [.claude, .codex],
            "one harness dropped out of the label — this is the one-icon bug"
        )
        XCTAssertEqual(
            FleetLabelImage.figures(
                FleetUsage(claude: nil, codex: 98.5, codexCount: 2), remaining: false
            ).map(\.harness),
            [.codex],
            "a harness with no countable account is absent, never drawn as zero"
        )
    }

    func testTheBarFillsOnTheSameAxisAsTheNumberBesideIt() {
        let used = FleetLabelImage.figures(both, remaining: false)
        XCTAssertEqual(used.map(\.shown), [94, 99])
        XCTAssertEqual(used.map(\.fill), [94, 98.5])

        let left = FleetLabelImage.figures(both, remaining: true)
        XCTAssertEqual(left.map(\.shown), [6, 2])
        XCTAssertEqual(
            left.map(\.fill), [6, 1.5],
            "the bar still fills by spend while the number counts down"
        )
    }

    func testValueFlipsTheAxisWithoutRounding() {
        XCTAssertEqual(FleetDisplay.value(98.5, remaining: false), 98.5)
        XCTAssertEqual(FleetDisplay.value(98.5, remaining: true), 1.5)
        XCTAssertEqual(FleetDisplay.value(140, remaining: true), 0, "clamped before the flip")
        XCTAssertEqual(FleetDisplay.value(-5, remaining: false), 0)
    }

    func testTheBrandGlyphsSurviveAColdFirstRender() throws {
        // The glyph box has to carry ink of its own. "Only the numbers
        // survived" is the shape every menu-bar failure here has taken, and the
        // ink-in-both-halves test cannot see it: the numbers alone satisfy that
        // one. Caches are dropped first so this exercises the menu bar's real
        // case, the FIRST label of a session, where nothing has resolved a
        // brand glyph yet.
        ProviderGlyph.resetCachesForTesting()
        guard let image = FleetLabelImage.make(
            both, remaining: false, showsBars: false, trailing: nil
        ) else { return XCTFail("a two-harness fleet must produce a label") }
        let columns = try inkedColumns(image)
        // The first figure reserves a glyph-wide box at x = 0, then its number.
        // Ink in that box is the mark; the numbers cannot reach it.
        let glyphBox = Int(
            (CGFloat(columns.count) / image.size.width) * FleetLabelImage.glyphBoxWidth
        )
        XCTAssertTrue(
            columns[..<glyphBox].contains(true),
            "the brand glyph drew nothing on a cold render — only the numbers survived"
        )
    }
}
