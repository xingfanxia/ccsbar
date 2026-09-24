import AppKit
import Foundation
import XCTest

@testable import CCSBarKit

/// The CBAR4-4 presentation logic on `StatusModel` (forecast sentence, chain line,
/// ordinals, strip helpers) — pure decisions over an injected status.
final class PanelLogicTests: XCTestCase {
    private func status(_ json: String) throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // A live (future-resets) 5h window so the forecast's five_hour_live holds
    // regardless of when the test runs.
    private let live5h = #""windows":[{"label":"5h","utilization_pct":%%,"resets_at":"2099-01-01T00:00:00+00:00"}]"#

    // MARK: ordinal — the 11/12/13 (and 111/112/113) English exceptions.

    func testOrdinalEdges() {
        XCTAssertEqual(StatusModel.ordinal(1), "1st")
        XCTAssertEqual(StatusModel.ordinal(2), "2nd")
        XCTAssertEqual(StatusModel.ordinal(3), "3rd")
        XCTAssertEqual(StatusModel.ordinal(4), "4th")
        XCTAssertEqual(StatusModel.ordinal(11), "11th")
        XCTAssertEqual(StatusModel.ordinal(12), "12th")
        XCTAssertEqual(StatusModel.ordinal(13), "13th")
        XCTAssertEqual(StatusModel.ordinal(21), "21st")
        XCTAssertEqual(StatusModel.ordinal(22), "22nd")
        XCTAssertEqual(StatusModel.ordinal(23), "23rd")
        XCTAssertEqual(StatusModel.ordinal(101), "101st")
        XCTAssertEqual(StatusModel.ordinal(111), "111th")
        XCTAssertEqual(StatusModel.ordinal(112), "112th")
        XCTAssertEqual(StatusModel.ordinal(113), "113th")
    }

    // MARK: forecast sentence + chain line (driven by the tested engine).

    @MainActor
    func testForecastSentenceAndChainLine() throws {
        let s = try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["xfx","cl-ax"],
         "profiles":[
           {"name":"xfx","active":true,"fallback":{"position":1,"threshold":95,"armed":true},\(live5h.replacingOccurrences(of: "%%", with: "62"))},
           {"name":"cl-ax","active":false,"fallback":{"position":2,"threshold":95,"armed":false,"last_resort":true},\(live5h.replacingOccurrences(of: "%%", with: "10"))}
         ]}
        """)
        let model = StatusModel(preview: s)
        XCTAssertEqual(model.forecastSentence, "Watching xfx — would switch to cl-ax at 95%")

        let xfx = s.profiles[0], clax = s.profiles[1]
        // NOTE: for a contiguous claude chain, fb.position == chain index + 1, so
        // these assertions can't distinguish the position-based ordinal from the
        // old firstIndex+1 walk. The pin that actually catches that regression is
        // ProviderTabsTests.testChainLineUsesHarnessScopedOrdinals (a codex member
        // is absent from fallback_chain, so a firstIndex walk returns nil there).
        XCTAssertEqual(model.chainLine(for: xfx),
                       "1st in chain · watched now — would rotate to cl-ax at 95% of the 5h window")
        // cl-ax has threshold 95 (not 100) yet is the last resort — proving the flag
        // is independent of the threshold, and the copy no longer mentions "100%".
        XCTAssertEqual(model.chainLine(for: clax),
                       "2nd in chain · last resort — parks here when nothing else has headroom")
    }

    // MARK: autoSwitchIdle — empty chain OR zero armed.

    @MainActor
    func testAutoSwitchIdle() throws {
        func idle(chain: String, armed: Bool) throws -> Bool {
            let s = try status("""
            {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx",
             "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[\(chain)],
             "profiles":[{"name":"xfx","active":true,"fallback":{"position":0,"threshold":95,"armed":\(armed)}}]}
            """)
            return StatusModel(preview: s).autoSwitchIdle
        }
        XCTAssertTrue(try idle(chain: "", armed: false))       // empty chain
        XCTAssertTrue(try idle(chain: "\"xfx\"", armed: false)) // chained but zero armed
        XCTAssertFalse(try idle(chain: "\"xfx\"", armed: true)) // an armed member
    }

    // MARK: wrap-off resume ETA — soonest future chain-member reset.

    @MainActor
    func testWrapOffResumeETA() throws {
        let s = try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":null,
         "wrap_off":true,"refresh_interval_ms":90000,"fallback_chain":["xfx"],
         "profiles":[{"name":"xfx","active":false,"fallback":{"position":0,"threshold":95,"armed":true},\(live5h.replacingOccurrences(of: "%%", with: "99"))}]}
        """)
        XCTAssertEqual(StatusModel(preview: s).wrapOffResumeETA?.hasPrefix("resets in"), true)
    }

    // MARK: inspection fallback = the CHAIN head when active is null (§3.1).

    @MainActor
    func testInspectedFallsBackToChainHeadWhenActiveNull() throws {
        // profiles list starts with alt, but the chain head is xfx → inspect xfx.
        let s = try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":null,
         "wrap_off":true,"refresh_interval_ms":90000,"fallback_chain":["xfx","cl-ax"],
         "profiles":[{"name":"alt","active":false},{"name":"xfx","active":false},{"name":"cl-ax","active":false}]}
        """)
        XCTAssertEqual(StatusModel(preview: s).inspected?.name, "xfx")
    }
}

final class PanelTopAnchorTests: XCTestCase {
    /// A page that got shorter shrinks the window to its content, keeps x and
    /// width, and hangs the top just under the menu bar.
    func testFittedFrameShrinksToContentAndHangsFromTheMenuBar() {
        let tall = NSRect(x: 1500, y: 394, width: 420, height: 869)
        let fitted = PanelTopAnchor.fittedFrame(tall, height: 640, menuBarBottom: 1264)
        XCTAssertEqual(fitted.minX, 1500)
        XCTAssertEqual(fitted.width, 420)
        XCTAssertEqual(fitted.height, 640)
        XCTAssertEqual(fitted.maxY, 1264 - PanelTopAnchor.gap)
    }
}

final class PlanUntilLabelTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// A plan end ahead reads "until <Mon d>"; past, nil, and junk read nothing.
    func testPlanUntilLabel() {
        let now = date("2026-09-24T12:00:00Z")
        let label = AccountRow.planUntilLabel("2026-10-21T12:06:00+00:00", now: now)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.hasPrefix("until "), label!)
        XCTAssertTrue(label!.contains("21"), label!)
        XCTAssertFalse(label!.contains("2026"), "same year: no year: \(label!)")
        XCTAssertNil(AccountRow.planUntilLabel("2026-08-31T08:19:37+00:00", now: now), "past")
        XCTAssertNil(AccountRow.planUntilLabel(nil, now: now))
        XCTAssertNil(AccountRow.planUntilLabel("not a date", now: now))
        XCTAssertTrue(AccountRow.planUntilLabel("2027-01-05T00:00:00Z", now: now)!.contains("2027"))
    }
}
