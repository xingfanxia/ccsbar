import Foundation

/// Whether an account has hit a 5h or weekly usage cap — a pure derivation over its
/// own windows, so the row pill, the muted name, and VoiceOver share ONE definition
/// of "spent" (design §5 danger role). A capped window throttles further requests
/// until it resets. The Fable trial window is deliberately NOT counted here: a maxed
/// Fable cap only blocks Fable requests, so the account is still usable otherwise.
///
/// This is the "at cap on the last read" signal — distinct from the rotation engine's
/// `exhausted()` (threshold-based AND gated on a live `resets_at`). They agree on a
/// fresh read; the row suppresses the pill on frozen data so a stale 100% can't
/// assert "spent" while the engine already treats the window as reset.
extension ProfileStatus {
    /// At/above this percent a window counts as spent. `99.5` (not `100`) so it agrees
    /// with the integer the bar shows — 99.5 rounds to "100%", and so does this.
    fileprivate static let spentThreshold = 99.5

    /// Whether a window's cap still BINDS: maxed AND its recorded reset is still
    /// ahead. A cached 100% whose `resets_at` has PASSED is yesterday's news —
    /// the limit already lifted server-side, only the snapshot is stale (the
    /// parked-codex case: no live session to refresh the cache, so the row wore
    /// "week spent" days after the reset). Mirrors the rotation engine's
    /// `window_live` gate, so the pill and the walk agree. A missing/unparseable
    /// `resets_at` keeps counting as spent — never optimistic on unknown data.
    fileprivate static func stillCapped(_ w: UsageWindow?) -> Bool {
        guard let w, w.utilizationPct >= spentThreshold else { return false }
        guard let iso = w.resetsAt, let reset = Theme.parseISO(iso) else { return true }
        return reset > Date()
    }

    /// The rolling weekly window's utilisation, mirroring `fiveHourPct` (one place for
    /// the `?? 0` fallback).
    var sevenDayPct: Double { sevenDay?.utilizationPct ?? 0 }

    /// The 5h session window is maxed (recovers in hours) and the cap still binds.
    var fiveHourSpent: Bool { Self.stillCapped(fiveHour) }

    /// The rolling weekly window is maxed (recovers over days) and the cap still binds.
    var weeklySpent: Bool { Self.stillCapped(sevenDay) }

    /// The spent-badge text, most-limiting window first, or nil when the account has
    /// headroom. "week spent" outranks "5h spent" — a weekly cap lasts days, a session
    /// cap hours — so the longer-lasting limit names the badge. Third-party accounts
    /// have no %-windows, so they never read as spent; codex rows DO carry %-windows
    /// (weekly-only as of 2026-07 — a missing 5h window simply never reads spent).
    var spentTag: String? {
        guard provider == "anthropic" || isCodex else { return nil }
        switch (fiveHourSpent, weeklySpent) {
        case (true, true): return "spent"
        case (false, true): return "week spent"
        case (true, false): return "5h spent"
        case (false, false): return nil
        }
    }
}
