import Foundation

/// Mirror of `~/.clauth/status.json` (schema 1), written by `clauth daemon`.
/// See clauth's `src/daemon/status_json.rs` for the authoritative shape.
struct DaemonStatus: Codable, Sendable {
    let schema: Int
    let generatedAt: String
    let activeProfile: String?
    let wrapOff: Bool
    let refreshIntervalMs: Int
    /// Ordered fallback-chain member names (the auto-switch order).
    let fallbackChain: [String]
    let profiles: [ProfileStatus]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case activeProfile = "active_profile"
        case wrapOff = "wrap_off"
        case refreshIntervalMs = "refresh_interval_ms"
        case fallbackChain = "fallback_chain"
        case profiles
    }

    /// Decode `fallback_chain` leniently — treat a missing field as empty so an
    /// older daemon's status.json still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        activeProfile = try c.decodeIfPresent(String.self, forKey: .activeProfile)
        wrapOff = try c.decode(Bool.self, forKey: .wrapOff)
        refreshIntervalMs = try c.decode(Int.self, forKey: .refreshIntervalMs)
        fallbackChain = try c.decodeIfPresent([String].self, forKey: .fallbackChain) ?? []
        profiles = try c.decode([ProfileStatus].self, forKey: .profiles)
    }
}

struct ProfileStatus: Codable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let active: Bool
    let provider: String
    let baseUrl: String?
    let tier: String?
    let hasLiveSession: Bool
    let fetchStatus: String?
    let fetchedAt: String?
    let nextRefreshAt: String?
    let autoStart: Bool
    let bellThreshold: Double?
    let fallback: FallbackInfo?
    let windows: [UsageWindow]
    let thirdParty: ThirdPartyInfo?

    enum CodingKeys: String, CodingKey {
        case name, active, provider, tier, fallback, windows
        case baseUrl = "base_url"
        case hasLiveSession = "has_live_session"
        case fetchStatus = "fetch_status"
        case fetchedAt = "fetched_at"
        case nextRefreshAt = "next_refresh_at"
        case autoStart = "auto_start"
        case bellThreshold = "bell_threshold"
        case thirdParty = "third_party"
    }

    /// The window with the given label (`"5h"`, `"7d"`, `"7d fable"`), or nil.
    func window(_ label: String) -> UsageWindow? { windows.first { $0.label == label } }

    /// The 5-hour window — the one that actually throttles a session.
    var fiveHour: UsageWindow? { window("5h") }
    var fiveHourPct: Double { fiveHour?.utilizationPct ?? 0 }

    /// The 7-day rolling window (weekly limit). `"7d"` is a clauth compile-time
    /// constant, so an exact match is safe.
    var sevenDay: UsageWindow? { window("7d") }

    /// The 7-day Fable-model window (fable weekly limit). Matched leniently: clauth
    /// derives this label from the server's model display name
    /// (`"7d " + display_name.lowercased()`), so it can be `"7d fable"`,
    /// `"7d fable 5"`, etc. Key on the `"7d …fable…"` shape, not an exact string.
    var fableWeek: UsageWindow? {
        windows.first { $0.label.hasPrefix("7d ") && $0.label.lowercased().contains("fable") }
    }

    /// Is this profile a member of the fallback chain?
    var inChain: Bool { fallback != nil }

    /// Freshness cue: numbers are trustworthy only on a live ("Fresh") read.
    var isStale: Bool { fetchStatus != nil && fetchStatus != "Fresh" }
}

struct FallbackInfo: Codable, Sendable {
    let position: Int
    let threshold: Double
    let armed: Bool
}

struct UsageWindow: Codable, Sendable, Identifiable {
    var id: String { label }
    let label: String
    let utilizationPct: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case label
        case utilizationPct = "utilization_pct"
        case resetsAt = "resets_at"
    }
}

struct ThirdPartyInfo: Codable, Sendable {
    let available: Bool
}
