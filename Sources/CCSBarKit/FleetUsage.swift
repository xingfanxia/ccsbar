import SwiftUI

/// FLEET-1: how much of each harness's whole account pool is spent right now.
///
/// The menu-bar label has always answered one account's question ("the active
/// one is 42% through its 5h window"). That is the wrong question when you run
/// seven accounts across two CLIs: what decides whether to start a long run is
/// how much the POOL has left, not the account you happen to be on. This is
/// that number, one per harness, because the two pools are independent — a
/// spent Claude fleet says nothing about Codex quota, and averaging them
/// together would produce a figure that describes no real limit.
///
/// **Definition.** Per account: `max(5h, 7d)` — the account is unusable when
/// EITHER unscoped window caps, so its spent-ness is the worse of the two. The
/// per-model windows (`7d fable`, `7d opus`) are deliberately excluded: they
/// cap one model, not the account, and folding them in would report a fleet as
/// spent because everyone's Fable week is gone while every account still runs
/// Sonnet fine. Fleet: the plain mean over countable accounts — accounts are
/// equal units within a harness (they hold comparable plans), and a weighted
/// mean would need quota sizes no API publishes.
///
/// **Countable** = has at least one unscoped window (so no third-party api-key
/// account, which reports a balance rather than a percentage), a live plan, and
/// a working login. A broken or lapsed account contributes nothing to the pool,
/// so counting it as 0% used would report headroom that cannot be spent; those
/// two states have their own loud surfaces (the row's danger pill, the inactive
/// group) and do not belong in a usage figure.
///
/// `nil` for a harness with no countable account — rendered as an absent bar,
/// never as 0%, which would read as "plenty left".
struct FleetUsage: Equatable, Sendable {
    /// Mean spent-ness of the Claude Code pool, 0…100.
    let claude: Double?
    /// Mean spent-ness of the Codex pool, 0…100.
    let codex: Double?

    /// Whether there is anything at all to draw.
    var isEmpty: Bool { claude == nil && codex == nil }

    static func compute(_ status: DaemonStatus?) -> FleetUsage {
        guard let status else { return FleetUsage(claude: nil, codex: nil) }
        return FleetUsage(
            claude: mean(status.profiles.filter { !$0.isCodex }),
            codex: mean(status.profiles.filter(\.isCodex))
        )
    }

    /// The pool's mean spent-ness, or `nil` when no account in it is countable.
    private static func mean(_ profiles: [ProfileStatus]) -> Double? {
        let spent = profiles.compactMap(spentPct)
        guard !spent.isEmpty else { return nil }
        return spent.reduce(0, +) / Double(spent.count)
    }

    /// One account's spent-ness, or `nil` when it does not belong in the pool.
    /// Split out so the exclusions are testable one at a time.
    static func spentPct(_ p: ProfileStatus) -> Double? {
        if p.authBroken || p.planInactive { return nil }
        let unscoped = [p.fiveHour, p.sevenDay].compactMap { $0?.utilizationPct }
        guard let worst = unscoped.max() else { return nil }
        return min(max(worst, 0), 100)
    }
}

/// FLEET-1: the fleet figure as two stacked capsule bars — Claude on top,
/// Codex beneath — sized for the menu bar.
///
/// Shape, not colour, carries the reading, for the same reason the rest of
/// `MenuBarLabelLadder` does: the menu bar template-renders its item and
/// flattens custom hues, so a red bar and a green one would look identical
/// there. `Color.primary` inherits whatever the bar is currently drawn in, in
/// both appearances, and the track is the same colour at low opacity — so the
/// filled fraction is legible as a fraction and nothing depends on a tint
/// surviving. A harness with no countable account draws an EMPTY TRACK rather
/// than a zero-length fill, so "nothing to report" cannot be misread as
/// "nothing used"; a harness with no accounts at all draws nothing.
struct FleetBars: View {
    let fleet: FleetUsage
    /// Bar length in points. Kept short: this rides beside the account name in
    /// a menu bar that already competes for width.
    var width: CGFloat = 22
    var thickness: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let claude = fleet.claude {
                bar(claude)
            }
            if let codex = fleet.codex {
                bar(codex)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.voiceOver(fleet))
        .help(Self.tooltip(fleet))
    }

    private func bar(_ pct: Double) -> some View {
        let fraction = min(max(pct / 100, 0), 1)
        return Capsule()
            .fill(Color.primary.opacity(0.25))
            .frame(width: width, height: thickness)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.primary)
                    // A non-zero reading always draws SOMETHING: below ~2% the
                    // exact fraction rounds to a sliver under one pixel, and a
                    // bar that renders as empty at 1% used says the wrong thing.
                    .frame(width: fraction > 0 ? max(fraction * width, thickness) : 0,
                           height: thickness)
            }
    }

    /// "Claude 43%, Codex 61% of the account pool used" — the sentence both the
    /// tooltip and VoiceOver read, so they can never drift apart.
    nonisolated static func tooltip(_ fleet: FleetUsage) -> String {
        let parts = [("Claude", fleet.claude), ("Codex", fleet.codex)]
            .compactMap { label, pct -> String? in
                guard let pct else { return nil }
                return "\(label) \(Int(pct.rounded()))%"
            }
        guard !parts.isEmpty else { return "No account pool to measure yet" }
        return parts.joined(separator: " · ")
            + " of the account pool used (the worse of each account's 5h and weekly window, averaged)"
    }

    nonisolated static func voiceOver(_ fleet: FleetUsage) -> String { tooltip(fleet) }
}
