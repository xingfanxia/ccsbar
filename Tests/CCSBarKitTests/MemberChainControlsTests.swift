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
