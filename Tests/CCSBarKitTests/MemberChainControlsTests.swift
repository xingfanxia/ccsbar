import Foundation
import Testing
@testable import CCSBarKit

// SCW-2/WKO surfacing: the per-member gate/override decode, the socket payload
// shapes (the daemon validates value types strictly — a wrong type is a loud
// rejection), and the ChainEdit vocabulary. All pure/local.

@Suite struct MemberChainControlsTests {
    @Test func fallbackInfoDecodesGatesAndOverrideWithOldDaemonDefaults() throws {
        // New daemon: all three fields present.
        let full = #"{"position":1,"threshold":95,"armed":true,"last_resort":false,"check_weekly":false,"check_scoped":true,"weekly_threshold":90}"#
        let fb = try JSONDecoder().decode(FallbackInfo.self, from: Data(full.utf8))
        #expect(fb.checkWeekly == false)
        #expect(fb.checkScoped == true)
        #expect(fb.weeklyThreshold == 90)

        // Old daemon: absent fields decode as clauth's defaults (gates ON,
        // no override) — never as "gates off".
        let old = #"{"position":1,"threshold":95,"armed":true}"#
        let fbOld = try JSONDecoder().decode(FallbackInfo.self, from: Data(old.utf8))
        #expect(fbOld.checkWeekly == true)
        #expect(fbOld.checkScoped == true)
        #expect(fbOld.weeklyThreshold == nil)
    }

    @Test func setMemberWeeklyEncodesClearAsExplicitNull() {
        // The daemon clears on an explicit JSON null — dropping the key would
        // also clear (absent = clear), but the seam pins the deliberate shape.
        var captured: [String: Any] = [:]
        _ = DaemonClient.setMemberWeekly("work", nil, send: { payload in
            captured = payload
            return .ok
        })
        #expect(captured["cmd"] as? String == "set_member_weekly")
        #expect(captured["profile"] as? String == "work")
        #expect(captured["value"] is NSNull)

        _ = DaemonClient.setMemberWeekly("work", 90, send: { payload in
            captured = payload
            return .ok
        })
        #expect(captured["value"] as? Double == 90)
    }

    @Test func memberWeeklyVocabularyMirrorsTheSocket() {
        // Parse mirrors the socket's 0…100 band, decimals allowed.
        #expect(ChainEdit.parseMemberWeekly("90") == 90)
        #expect(ChainEdit.parseMemberWeekly(" 97.5 ") == 97.5)
        #expect(ChainEdit.parseMemberWeekly("150") == nil)
        #expect(ChainEdit.parseMemberWeekly("-1") == nil)
        #expect(ChainEdit.parseMemberWeekly("") == nil)
        #expect(ChainEdit.parseMemberWeekly("inf") == nil)
        // The clear affordance names the chain default it falls back to.
        #expect(ChainEdit.followChainDefaultLabel(98) == "Follow chain default (98%)")
        #expect(ChainEdit.followChainDefaultLabel(97.5) == "Follow chain default (97.5%)")
    }
}

// MARK: - Codex members have no per-member judgment (UPS-18)
//
// clauth's codex walk hands every member the DEFAULT threshold and the chain-wide
// weekly line, so `set_threshold` / `set_last_resort` / `set_member_weekly` / the
// gates all REFUSE a codex member. These pin the client side of that contract: the
// knobs are not offered, and the number the panel shows is the one that governs.

@Suite struct CodexMemberChainControlsTests {
    private func status(codexWeekly: String?, claudeWeekly: String?) throws -> DaemonStatus {
        let cx = codexWeekly.map { "\"codex_weekly_switch_threshold\":\($0)," } ?? ""
        let cl = claudeWeekly.map { "\"weekly_switch_threshold\":\($0)," } ?? ""
        return try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"cl-a",
         "wrap_off":false,"refresh_interval_ms":90000,\(cl)\(cx)
         "fallback_chain":["cl-a"],"codex_fallback_chain":["cx-a"],
         "profiles":[
           {"name":"cl-a","active":true,
            "fallback":{"position":1,"threshold":80,"armed":true},"windows":[]},
           {"name":"cx-a","active":true,"provider":"openai","harness":"codex",
            "fallback":{"position":1,"threshold":95,"armed":true},"windows":[]}
         ]}
        """.utf8))
    }

    @Test func theFourPerMemberKnobsAreOfferedToClaudeAndRefusedToCodex() {
        // One spelling of the rule, because both surfaces read it.
        #expect(ChainEdit.offersPerMemberKnobs(isCodex: false))
        #expect(!ChainEdit.offersPerMemberKnobs(isCodex: true))
    }

    @Test func thePanelReadsTheCodexChainsOwnWeeklyLineNotClaudes() throws {
        // The two chains keep independent values in independent files; editing the
        // line writes both, but codex-profiles.toml is hand-editable and can diverge.
        let s = try status(codexWeekly: "90", claudeWeekly: "98")
        #expect(s.weeklyLine(for: .codex) == 90)
        #expect(s.weeklyLine(for: .claude) == 98)
    }

    @Test func anOlderDaemonWithoutTheCodexKeyFallsBackToTheClaudeLine() throws {
        // A daemon too old to publish the codex line kept the two equal through its
        // own edits, so the claude number is the honest answer there — never the
        // hardcoded default, which would silently contradict a configured chain.
        let s = try status(codexWeekly: nil, claudeWeekly: "90")
        #expect(s.weeklyLine(for: .codex) == 90)
    }

    @Test func withNeitherKeyPublishedBothHarnessesReadTheDocumentedDefault() throws {
        let s = try status(codexWeekly: nil, claudeWeekly: nil)
        #expect(s.weeklyLine(for: .codex) == ChainEdit.defaultWeeklyLine)
        #expect(s.weeklyLine(for: .claude) == ChainEdit.defaultWeeklyLine)
    }

    @Test func theChainChipNamesTheAxisOnlyWhereTheNumberIsAWeeklyOne() {
        // A claude chip's number is the member's own 5h threshold; the rail legend
        // already says so, so it stays bare. A codex chip's is the chain-wide weekly
        // line — printing it bare would read as a per-member setting it is not.
        #expect(ChainEdit.chipThresholdLabel(80, isCodex: false, weeklyLine: 98) == "@80")
        #expect(ChainEdit.chipThresholdLabel(95, isCodex: true, weeklyLine: 90) == "7d@90")
    }

    @Test func theCodexChipIgnoresThePublishedPerMemberThreshold() {
        // status_json's codex_fallback fills `threshold` with the walk's DEFAULT
        // constant for EVERY member. Two codex members therefore publish the same
        // number, and it is not the one they rotate on — the chip must not show it.
        let first = ChainEdit.chipThresholdLabel(95, isCodex: true, weeklyLine: 90)
        let second = ChainEdit.chipThresholdLabel(50, isCodex: true, weeklyLine: 90)
        #expect(first == second)
        #expect(!first.contains("95") && !second.contains("50"))
    }

    @Test func theInertChipStatesTheWeeklyLineWithItsAxis() {
        #expect(ChainEdit.codexMemberLineLabel(90) == "7d @ 90%")
        #expect(ChainEdit.codexMemberLineLabel(97.5) == "7d @ 97.5%")
    }

    @Test func theCodexLegendExplainsTheAbsenceInsteadOfNamingTheFlag() {
        // §7: outcome language. It must say what governs, not "set_threshold is
        // refused" — and it must not leak the internal knob names.
        let legend = ChainEdit.codexMemberLegend
        #expect(legend.contains("weekly"))
        for jargon in ["set_threshold", "wrap_off", "last_resort", "refuse"] {
            #expect(!legend.lowercased().contains(jargon))
        }
    }
}
