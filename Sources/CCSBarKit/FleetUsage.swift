import AppKit
import SwiftUI

/// FLEET-1: how much of each harness's whole account pool is spent right now.
///
/// The menu-bar label used to answer one account's question ("the active one is
/// 75% through its 5h window"). That is the wrong question when you run seven
/// accounts across two CLIs: what decides whether to start a long run is how
/// much the POOL has left, not the account you happen to be on. This is that
/// number, one per harness, because the two pools are independent — a spent
/// Claude fleet says nothing about Codex quota, and averaging them together
/// would produce a figure that describes no real limit.
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
/// group) and do not belong in a usage figure. `count` carries how many
/// accounts each figure came from, because "75%" over one surviving account and
/// over five are different facts and the tooltip has to be able to say which.
///
/// `nil` for a harness with no countable account — rendered as an absent bar,
/// never as 0%, which would read as "plenty left".
struct FleetUsage: Equatable, Sendable {
    /// Mean spent-ness of the Claude Code pool, 0…100, and how many accounts
    /// it averaged.
    let claude: Double?
    let claudeCount: Int
    /// Mean spent-ness of the Codex pool, 0…100, and how many accounts.
    let codex: Double?
    let codexCount: Int
    /// Accounts with a usage window that were LEFT OUT — an expired login or a
    /// lapsed plan. Named in the tooltip because the figure is "of everything
    /// you can actually use", and an operator who owns seven accounts and sees
    /// a pool of one deserves to be told why rather than left to wonder.
    let excluded: Int

    init(
        claude: Double?,
        claudeCount: Int = 0,
        codex: Double?,
        codexCount: Int = 0,
        excluded: Int = 0
    ) {
        self.claude = claude
        self.claudeCount = claudeCount
        self.codex = codex
        self.codexCount = codexCount
        self.excluded = excluded
    }

    /// Whether there is anything at all to draw.
    var isEmpty: Bool { claude == nil && codex == nil }

    static func compute(_ status: DaemonStatus?) -> FleetUsage {
        guard let status else { return FleetUsage(claude: nil, codex: nil) }
        let cc = pool(status.profiles.filter { !$0.isCodex })
        let cx = pool(status.profiles.filter(\.isCodex))
        // Left out = has a window to report, but its login or plan says the
        // quota cannot be spent. An account with no window at all (a
        // third-party balance account) is not in this population.
        let excluded = status.profiles.filter {
            ($0.authBroken || $0.planInactive) && ($0.fiveHour != nil || $0.sevenDay != nil)
        }.count
        return FleetUsage(
            claude: cc.0, claudeCount: cc.1,
            codex: cx.0, codexCount: cx.1,
            excluded: excluded
        )
    }

    /// The pool's mean spent-ness and its account count; `nil` mean when no
    /// account in it is countable.
    private static func pool(_ profiles: [ProfileStatus]) -> (Double?, Int) {
        let spent = profiles.compactMap(spentPct)
        guard !spent.isEmpty else { return (nil, 0) }
        return (spent.reduce(0, +) / Double(spent.count), spent.count)
    }

    /// One account's spent-ness, or `nil` when it does not belong in the pool.
    /// Split out so the exclusions are testable one at a time.
    static func spentPct(_ p: ProfileStatus) -> Double? {
        if p.authBroken || p.planInactive { return nil }
        let unscoped = [p.fiveHour, p.sevenDay].compactMap { $0?.utilizationPct }
        guard let worst = unscoped.max() else { return nil }
        return min(max(worst, 0), 100)
    }

    /// "Claude 75% of 1 account · Codex 95% of 2 accounts" — the sentence the
    /// tooltip and VoiceOver share, so they cannot drift apart. The counts are
    /// in it because the bars cannot show them and a pool of one is a different
    /// fact from a pool of five.
    nonisolated static func sentence(_ fleet: FleetUsage, remaining: Bool = false) -> String {
        let parts = [
            ("Claude", fleet.claude, fleet.claudeCount),
            ("Codex", fleet.codex, fleet.codexCount),
        ].compactMap { label, pct, n -> String? in
            guard let pct else { return nil }
            let shown = FleetDisplay.shown(pct, remaining: remaining)
            return "\(label) \(shown)% of \(n) account\(n == 1 ? "" : "s")"
        }
        guard !parts.isEmpty else { return "No account pool to measure yet" }
        let left = fleet.excluded == 0
            ? ""
            : "; \(fleet.excluded) more left out, their login or plan says the quota can't be spent"
        return parts.joined(separator: " · ")
            + (remaining ? " LEFT" : " used")
            + " (the worse of each account's 5h and weekly window, averaged\(left))"
    }
}

/// FLEET-1: the two knobs the menu-bar label reads, and the one rule that turns
/// a pool figure into the number shown.
///
/// Both live in `UserDefaults` and are read with `@AppStorage` from the views
/// that need them — never from inside an `ObservableObject`, where `@AppStorage`
/// is a `DynamicProperty` that would silently stop publishing (the same trap
/// `StatusModel.tab` documents).
enum FleetDisplay {
    /// Draw a bar beside each figure. OFF by default: the figures are what the
    /// decision needs, and AX found the bars added width without adding an
    /// answer (2026-09-09). The bar stays available for whoever reads a shape
    /// faster than a number.
    static let barsKey = "fleetShowsBars"
    /// Show what is LEFT rather than what is spent. Off by default, because
    /// every other usage surface in ccsbar and in clauth's own TUI reports
    /// utilisation, and one surface counting the other way is how "8% in
    /// reserve" got read as "8% left" the last time it was tried.
    static let remainingKey = "fleetShowsRemaining"

    /// The integer the label prints for a pool figure. `remaining` flips the
    /// axis; the rounding happens AFTER the flip so 99.6% used reads as 0 left,
    /// not 1 — a rounded-up remainder promises headroom that is already gone.
    nonisolated static func shown(_ pct: Double, remaining: Bool) -> Int {
        let clamped = min(max(pct, 0), 100)
        return Int((remaining ? 100 - clamped : clamped).rounded())
    }
}

/// FLEET-1: the fleet figure drawn as a template NSImage — two stacked bars,
/// Claude over Codex.
///
/// **Why a drawn image and not SwiftUI shapes.** `MenuBarExtra`'s label is
/// rendered by AppKit into a status-item image, and only `Text` and `Image`
/// survive that trip: a first cut built the bars from `Capsule().fill(…)` and
/// they rendered as NOTHING in the menu bar while every unit test passed
/// (verified 2026-09-09 against a build that carried the code). Drawing them
/// ourselves is the only way to put a real bar up there.
///
/// The image is a TEMPLATE, so the system tints it for light and dark menu bars
/// and for the highlighted state — which is also why the fill can carry no
/// colour of its own. Shape does the whole job: a full-height fill against a
/// low-alpha track. Alpha survives templating, so the track reads as a track.
enum FleetBarsImage {
    /// Bar geometry, in points. Deliberately small: this rides beside the
    /// numbers in a menu bar that already competes for width.
    static let width: CGFloat = 20
    static let barHeight: CGFloat = 4
    static let gap: CGFloat = 2

    /// A template image of the pool bars, or `nil` when there is nothing to
    /// draw. A harness with no countable account contributes NO bar (not an
    /// empty one): a full-width empty track reads as "nothing used", which is
    /// the opposite of "nothing known".
    static func make(_ fleet: FleetUsage) -> NSImage? {
        let values = [fleet.claude, fleet.codex].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        let height = CGFloat(values.count) * barHeight + CGFloat(values.count - 1) * gap
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        for (i, pct) in values.enumerated() {
            // Top row first: AppKit's origin is bottom-left, so the first value
            // has to be drawn at the highest y or Claude and Codex swap places.
            let y = height - CGFloat(i + 1) * barHeight - CGFloat(i) * gap
            let track = NSRect(x: 0, y: y, width: width, height: barHeight)
            let radius = barHeight / 2
            NSColor.black.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            let fraction = min(max(pct / 100, 0), 1)
            guard fraction > 0 else { continue }
            // Never thinner than the cap diameter: below ~4% the exact fraction
            // rounds to a sliver under a pixel, and a bar that renders empty at
            // 2% used says the wrong thing.
            let filled = max(fraction * width, barHeight)
            let fill = NSRect(x: 0, y: y, width: filled, height: barHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// ONE bar for one pool, sized for the menu bar's line. Used when the bars
    /// are switched on: each rides inside its harness's own group, after the
    /// brand glyph, so a bar can never be read against the wrong harness.
    static func one(_ pct: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: barHeight))
        image.lockFocus()
        let radius = barHeight / 2
        let track = NSRect(x: 0, y: 0, width: width, height: barHeight)
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let fraction = min(max(pct / 100, 0), 1)
        if fraction > 0 {
            let filled = max(fraction * width, barHeight)
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: filled, height: barHeight),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
