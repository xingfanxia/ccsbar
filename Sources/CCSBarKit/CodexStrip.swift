import SwiftUI

/// The CODEX page's exception surface (TABS-1) — the codex sibling of
/// `StatusStrip`, priority-ordered the same way: dead-daemon banner > switch
/// lifecycle (codex-harness switches only) > rate-limit card > active line.
///
/// Deliberately STATE, not prediction: the daemon publishes no codex forecast
/// (its `forecast` field is claude-only), and a client-side mirror of the codex
/// walk is exactly the drift the published claude forecast was built to kill —
/// so this strip reports what IS (active login, credential age, limiter verdict)
/// and leaves "what would happen next" to a future daemon-published field.
struct CodexStrip: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if model.liveness.isStalled {
                DeadDaemonBanner(model: model)
            } else if model.switchPhase != .idle, model.switchHarness == .codex {
                SwitchLifecycleRow(phase: model.switchPhase, currentName: model.activeCodex?.name)
            } else if let active = model.activeCodex {
                if let limited = Self.rateLimitLine(active) {
                    rateLimitCard(limited, for: active)
                } else {
                    activeLine(active)
                }
            } else if !model.profiles(for: .codex).isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("No active codex account — pick one below.").font(Theme.meta)
                    Spacer(minLength: 0)
                }
            }
            // Zero codex profiles: no strip at all — the accounts section's
            // first-run door owns that state.
        }
        .padding(.horizontal, 19).padding(.top, 5).padding(.bottom, 10)
    }

    // MARK: - Active line

    private func activeLine(_ active: ProfileStatus) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.codex)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active \(active.name) — codex uses this login")
                    .font(Theme.meta).fixedSize(horizontal: false, vertical: true)
                Text(stampLine(active)).font(Theme.sub).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// "login captured 2h ago · updated 3s ago" — the CREDENTIAL age (when the
    /// stored login was captured/adopted) is distinct from usage freshness, and
    /// naming it prevents reading a week-old capture as a week-old panel.
    private func stampLine(_ active: ProfileStatus) -> String {
        var parts: [String] = []
        if let captured = active.codexSnapshotAt, let d = Theme.parseISO(captured) {
            parts.append("login captured \(StatusModel.ago(Int(Date().timeIntervalSince(d))))")
        }
        parts.append(model.freshnessWord)
        return parts.joined(separator: " · ")
    }

    // MARK: - Rate-limit card

    /// The limiter verdict as user words, or nil when not limited.
    /// `codex_rate_limit_reached` is a TWO-window signal: `"primary"` = the 5h
    /// window rejected the last request, `"secondary"` = the weekly (7d) window.
    /// An unrecognized future value degrades to a generic line, never hides.
    ///
    /// LAPSE CROSS-CHECK (the daemon contract, status_json.rs: "Readers cross-check
    /// the named window's resets_at — a lapsed window clears the badge"): the
    /// verdict is a STICKY cached value, only overwritten on the next usage event,
    /// so after the named window's reset passes the daemon no longer considers the
    /// account blocked (its `codex_limiter_blocked` gates on window liveness) while
    /// the raw field still says "primary". Mirror that gate here — a recovered
    /// account must not wear a red limit card the daemon would ignore. The
    /// unrecognized case degrades the same way the daemon does: limited only while
    /// EITHER window is still live. `now` is injected for deterministic tests.
    static func rateLimitLine(
        _ p: ProfileStatus, now: Date = Date()
    ) -> (message: String, resetsAt: String?)? {
        func live(_ w: UsageWindow?) -> Bool {
            guard let iso = w?.resetsAt, let resets = Theme.parseISO(iso) else { return false }
            return resets > now
        }
        switch p.codexRateLimitReached {
        case nil:
            return nil
        case "primary":
            guard live(p.fiveHour) else { return nil }
            return ("\(p.name) hit its 5h window", p.fiveHour?.resetsAt)
        case "secondary":
            guard live(p.sevenDay) else { return nil }
            return ("\(p.name) hit its weekly window", p.sevenDay?.resetsAt)
        case .some:
            // A verdict that names no window (the backend's 2026-09 spelling,
            // `"rate_limit_reached"`). The body's own percentages still say
            // which window is spent: a live window reading full is named,
            // with its reset; when neither reads full the line stays generic
            // rather than pinning the block on an 80% window.
            let fullLive = [(p.sevenDay, "weekly"), (p.fiveHour, "5h")]
                .first { w, _ in live(w) && (w?.utilizationPct ?? 0) >= 100 }
            if let (w, name) = fullLive {
                return ("\(p.name) hit its \(name) window", w?.resetsAt)
            }
            guard live(p.fiveHour) || live(p.sevenDay) else { return nil }
            return ("\(p.name) is rate-limited", nil)
        }
    }

    /// "1 free reset banked" — only worth saying beside a spent window, and
    /// only when the daemon has actually carried a count (nil = silent; a
    /// zero is silent too, since "0 banked" is noise next to a limit card).
    static func bankedLine(_ p: ProfileStatus) -> String? {
        guard let n = bankedCount(p) else { return nil }
        return n == 1 ? "1 free reset banked" : "\(n) free resets banked"
    }

    /// The banked count worth showing, or `nil` when there is nothing to say:
    /// a daemon that never carried the field (older, or a claude profile) and a
    /// zero are both silent — "0 banked" is noise, and an absent count is not a
    /// zero. Shared with the account row's chip so the two surfaces cannot
    /// disagree about when a reset exists.
    static func bankedCount(_ p: ProfileStatus) -> Int? {
        guard let n = p.codexResetCredits, n > 0 else { return nil }
        return n
    }

    private func rateLimitCard(_ limited: (message: String, resetsAt: String?), for active: ProfileStatus) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.sub).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(limited.message) — auto-switch rotates at the session boundary")
                    .font(Theme.meta).fixedSize(horizontal: false, vertical: true)
                if let hint = Theme.resetHint(limited.resetsAt) {
                    Text(hint).font(Theme.sub).foregroundStyle(.secondary)
                }
                if let banked = Self.bankedLine(active) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 12))
                        Text(banked)
                    }
                    .font(Theme.sub).foregroundStyle(Theme.codex)
                    .help("A rate-limit reset OpenAI granted this account. Redeem it from the Codex app (Reset usage) — clauth only reads the count.")
                }
            }
            Spacer(minLength: 0)
        }
    }
}
