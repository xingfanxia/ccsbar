import XCTest

@testable import CCSBarKit

/// Confirms open inside the row that asked for them (2026-09-27: the
/// panel-top banners sat far from the account the user had just right-clicked).
/// Pure routing over the model's pending state; nothing is dispatched.
final class InlineConfirmTests: XCTestCase {
    private func status() throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["xfx","cl-ax"],
         "profiles":[
           {"name":"xfx","active":true,"fallback":{"position":1,"threshold":95,"armed":true}},
           {"name":"cl-ax","active":false,"fallback":{"position":2,"threshold":100,"armed":false}},
           {"name":"alt","active":false}
         ]}
        """.utf8))
    }

    @MainActor
    func testADeleteConfirmsInItsOwnRowOnly() throws {
        let model = StatusModel(preview: try status(), liveness: .down)
        model.requestDelete("alt")
        guard case .delete(let prompt)? = RowConfirm.armed(for: "alt", in: model) else {
            return XCTFail("the asking row carries the delete confirm")
        }
        XCTAssertTrue(prompt.contains("alt"))
        XCTAssertNil(RowConfirm.armed(for: "xfx", in: model), "no other row confirms")
        model.cancelDelete()
        XCTAssertNil(RowConfirm.armed(for: "alt", in: model))
    }

    @MainActor
    func testARemovalFromTheRowMenuConfirmsInTheRow() throws {
        let model = StatusModel(preview: try status(), liveness: .down)
        model.requestRemove("xfx")
        XCTAssertFalse(model.pendingRemovalFromChain)
        XCTAssertEqual(RowConfirm.armed(for: "xfx", in: model),
                       .remove("This disables auto-switch — remove anyway?"))
    }

    /// Asked for in the chain editor, it confirms there, not in the account row.
    @MainActor
    func testARemovalFromTheChainEditorStaysOutOfTheRow() throws {
        let model = StatusModel(preview: try status(), liveness: .down)
        model.requestRemove("xfx", fromChain: true)
        XCTAssertTrue(model.pendingRemovalFromChain)
        XCTAssertEqual(model.pendingRemoval, "xfx")
        XCTAssertNil(RowConfirm.armed(for: "xfx", in: model))
    }

    func testEachConfirmCarriesItsSeverityHue() {
        XCTAssertEqual(RowConfirm.delete("").tint, Theme.danger)
        XCTAssertEqual(RowConfirm.reset("").tint, Theme.codex)
        XCTAssertEqual(RowConfirm.remove("").tint, Theme.warning)
    }
}

/// The codex app-server notice (clauth `codex_app_server_stale`).
final class CodexServerNoticeTests: XCTestCase {
    func testTheStaleDaemonKeyDecodes() throws {
        let s = try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":2,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":null,
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[],
         "codex_app_server_stale":{"started_at":"2099-01-01T00:00:00+00:00"}}
        """.utf8))
        XCTAssertEqual(s.codexAppServerStale?.startedAt, "2099-01-01T00:00:00+00:00")
        let none = try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":2,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":null,
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[],"codex_app_server_stale":null}
        """.utf8))
        XCTAssertNil(none.codexAppServerStale)
    }

    @MainActor
    func testTheNoticeNamesTheAccountTasksAreNotOnAndWhatRestartCosts() {
        let now = Theme.parseISO("2026-09-28T05:00:00Z")!
        let text = CodexServerNotice.message(
            activeName: "ax-codex-dev0", startedAt: "2026-09-26T11:43:00Z", now: now)
        XCTAssertTrue(text.contains("not ax-codex-dev0"), text)
        XCTAssertTrue(text.contains("started"), text)
        XCTAssertTrue(text.contains("tasks mid-turn stop that turn"), text)
    }
}
