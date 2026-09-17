import AppKit
import SwiftUI

/// Palette + usage helpers. Four color ROLES, one meaning per hue (CBAR-4-DESIGN
/// §5): terracotta = ACTIVE, darkened terracotta = the ACT verb, sapphire =
/// ARMED/WATCHING, and green/amber/red = HEADROOM/HEALTH. Structural text uses
/// semantic colors so it flips correctly in light/dark.
enum Theme {
    /// #D97757 terracotta — ACTIVE only (checkmark, active-name tint, active
    /// outline). Never armed, never a healthy bar, never generic-interactive.
    static let accent = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341)
    /// #B85C33 darkened terracotta — the ACT verb: fill of the "Switch to X"
    /// button under white text (≥4.5:1 AA). The brand hue acts only where the
    /// user acts.
    static let actVerb = Color(.sRGB, red: 0.722, green: 0.361, blue: 0.200)
    /// #43ABE5 sapphire — ARMED / WATCHING / auto-switch identity (forecast bolt,
    /// armed chip ring, pending-switch pulse).
    static let sapphire = Color(.sRGB, red: 0.263, green: 0.671, blue: 0.898)
    /// #49A3B0 — codexbar's OWN codex brand color, copied VERBATIM from its
    /// provider color map (CodexProviderDescriptor → ProviderBranding →
    /// `ProviderColor(red: 73/255, green: 163/255, blue: 176/255)`). Every
    /// codex identity surface (tab pill, active marks, verb fills) uses this;
    /// claude keeps its terracotta — one brand hue per provider, per the map.
    static let codex = Color(.sRGB, red: 73.0 / 255, green: 163.0 / 255, blue: 176.0 / 255)

    // HEADROOM/HEALTH as light/dark DYNAMIC pairs (Catppuccin Latte in light,
    // Mocha in dark) — fixes the 1.3–2.3:1 light-mode contrast failures the flat
    // Mocha hues had. green = live/healthy, amber = nearing, red = at/over.
    static let success = dynamic(light: 0x40A02B, dark: 0xA6E3A1)
    static let warning = dynamic(light: 0xDF8E1D, dark: 0xF9E2AF)
    static let danger = dynamic(light: 0xD20F39, dark: 0xF38BA8)

    // MARK: - Type scale

    /// ONE ladder for the whole panel, because there was not one. It carried
    /// ~146 font calls: mostly macOS's semantic roles — where `.subheadline` is
    /// 11pt and `.caption` is 10 — with hard-coded 8-to-12pt chrome between
    /// them. AX could not read the account rows (2026-09-09, 「字和badge还有图标
    /// 可读性还是太差了好小」), and with no scale there was no lever to pull:
    /// "bigger" meant editing every call site by hand and arriving somewhere
    /// inconsistent.
    ///
    /// Every step is one to three points above the role it replaced, and the
    /// ORDER is preserved, so nothing that used to sit above something else now
    /// sits level with it. The panel widened to 400pt to hold it.
    ///
    /// Sizes are fixed rather than semantic. macOS's roles are the reason the
    /// panel read small, and `dynamicTypeSize` — the one lever that would have
    /// lifted them all at once — does nothing on macOS (measured: an identical
    /// render at `.xLarge`). Pinning them is what keeps the decision visible.

    /// Headings and an account's name — the largest thing in a row.
    static let title = Font.system(size: 16, weight: .semibold)
    /// A hero percentage: the name's twin, with digits that do not reflow.
    static let figure = Font.system(size: 16, weight: .semibold).monospacedDigit()
    /// Primary interface text — menu rows, buttons, a card's own heading.
    static let body = Font.system(size: 14)
    /// Secondary text: tier, provider, reset countdowns, availability.
    static let meta = Font.system(size: 13.5)
    /// Tertiary text, a step under `meta`.
    static let sub = Font.system(size: 13)
    /// Dim supporting text: which login a profile holds, window ticks, hints.
    static let fine = Font.system(size: 12.5)
    /// The dimmest chrome.
    static let micro = Font.system(size: 11.5)
    /// Every pill — spent, login expired, banked resets, watching, harness tag.
    /// Semibold rather than medium: a capsule's whole job is to be caught out
    /// of the corner of an eye, and it was too quiet on a tinted ground to do
    /// it.
    static let badge = Font.system(size: 12, weight: .semibold)
    /// A row's active mark, sized to sit WITH the name rather than under it.
    static let mark = Font.system(size: 15)
    /// A section's own label.
    static let sectionLabel = Font.system(size: 12.5, weight: .semibold)

    /// Progress-bar track — a faint neutral that adapts to light/dark.
    static let track = Color.primary.opacity(0.10)

    /// A hue that swaps between a Latte (light) and Mocha (dark) hex by the system
    /// appearance, so headroom colors keep AA contrast in both modes.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: Int) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// Where the ramp turns. ABSOLUTE percentages of the window, not fractions
    /// of the account's rotation threshold, which is what they were: a window
    /// with no chain line defaults to `threshold = 100`, so amber only arrived
    /// at 80 and red at 100 — and every bar on a panel of 70-to-85%-spent
    /// accounts was still green (AX, 2026-09-16: 「现在一直是绿色」).
    ///
    /// A bar exists for the pre-attentive read of how much is gone. WHERE the
    /// daemon rotates is a different fact with its own channel — the tick
    /// `UsageBar` draws — so the colour is free to answer the human question.
    static let warningPct: Double = 70
    static let dangerPct: Double = 90

    /// Bar fill by utilization (§5): green headroom → amber at 70 → red at 90.
    /// Terracotta is NOT used here — a healthy bar is green, not the
    /// (active-only) brand hue.
    ///
    /// `threshold` survives as a FLOOR on urgency and never a ceiling: an
    /// account set to rotate at 60 is past its own line at 65, and reading calm
    /// until 90 would hide the state the daemon is already acting on. It can
    /// only make a bar more alarming, never less. Amber keeps the same fraction
    /// of wherever the red line ends up, so an early-rotating account still
    /// gets a warning band instead of jumping green → red in one step.
    static func usageColor(_ pct: Double, threshold: Double = 100) -> Color {
        let red = min(dangerPct, threshold)
        if pct >= red { return danger }
        if pct >= red * (warningPct / dangerPct) { return warning }
        return success
    }

    /// Parse an ISO-8601 timestamp as the daemon writes it. `resets_at` carries
    /// microseconds (`…T14:19:59.519183+00:00`), which the plain
    /// `.withInternetDateTime` parser rejects — try fractional first, then plain,
    /// then strip the sub-second digits (`.withFractionalSeconds` only promises
    /// milliseconds, not the daemon's 6 digits).
    static func parseISO(_ iso: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = parser.date(from: iso) { return d }
        parser.formatOptions = [.withInternetDateTime]
        if let d = parser.date(from: iso) { return d }
        let stripped = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return parser.date(from: stripped)
    }

    /// Compact "resets in" hint from an ISO-8601 timestamp — `resets in 5d 16h`,
    /// `resets in 3h 20m`, `resets in 12m`, or nil when absent or already past.
    /// Two units max, coarsest first (weekly windows read in days, not "136h").
    static func resetHint(_ iso: String?) -> String? {
        guard let iso, let date = parseISO(iso) else { return nil }
        return resetHintText(secondsRemaining: Int(date.timeIntervalSinceNow))
    }

    /// Pure d/h/m formatting — the finding-prone bit, split from the `Date.now`
    /// read so the boundary logic is deterministically unit-testable (the clock is
    /// the caller's). `secs <= 0` (already past) → nil.
    static func resetHintText(secondsRemaining secs: Int) -> String? {
        guard secs > 0 else { return nil }
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return h > 0 ? "resets in \(d)d \(h)h" : "resets in \(d)d" }
        if h > 0 { return m > 0 ? "resets in \(h)h \(m)m" : "resets in \(h)h" }
        return "resets in \(m)m"
    }
}

/// A thin rounded usage bar — the CodexBar-style meter. Track + fill, clamped to
/// 0…100, with an optional in-track threshold tick (design §8 Roster graft): a
/// hairline at the account's own auto-switch threshold so the distance-to-rotation
/// is a pre-attentive visible gap.
struct UsageBar: View {
    let pct: Double
    let color: Color
    var height: CGFloat = 6
    /// The account's 5h auto-switch threshold (0…100); nil hides the tick. Ticks at
    /// 100 (the sink / no-threshold windows) are suppressed — a tick at the bar end
    /// is noise.
    var threshold: Double? = nil
    /// Track color override — the default near-invisible neutral works on the
    /// panel background; a bar sitting ON a solid brand fill (the selected
    /// provider pill) passes a translucent white instead.
    var track: Color = Theme.track
    /// Fill by what is LEFT rather than by what is spent.
    ///
    /// `pct` is ALWAYS the spent percentage, whichever way this is set — which
    /// is what keeps the colour honest. Callers pass a hue derived from spend
    /// (`Theme.usageColor`), so in remaining mode a short bar is also a red one
    /// and a long bar is green: length and colour say the same thing, "more is
    /// better", instead of pointing opposite ways. The menu-bar label learned
    /// this the hard way, where a bar filled 94% by spend sat next to the
    /// number "6 left".
    /// No default, deliberately. A bar carries no number of its own, so a bar
    /// on the wrong axis is the one surface that cannot self-correct — and the
    /// tab underline sat above the account rows filling by spend while they
    /// counted down, because a defaulted parameter let a new call site skip the
    /// decision silently. Every caller states the axis or does not compile.
    var remaining: Bool

    /// Where the fill ends and where the tick sits, on the axis currently being
    /// read. Pure, because the panel has no render test and this is the exact
    /// pair that went wrong in the menu bar: a bar filled 94% by spend sitting
    /// beside the number "6 left". `pct` and `threshold` are ALWAYS spent
    /// values; this is the only place either one flips.
    nonisolated static func geometry(
        pct: Double,
        threshold: Double?,
        remaining: Bool
    ) -> (fill: Double, tick: Double?) {
        (
            FleetDisplay.value(pct, remaining: remaining),
            threshold.map { FleetDisplay.value($0, remaining: remaining) }
        )
    }

    var body: some View {
        let (shown, tick) = Self.geometry(pct: pct, threshold: threshold, remaining: remaining)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, shown / 100)) * geo.size.width)
                if let tick, tick > 0, tick < 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: height)
                        .offset(x: min(1, tick / 100) * geo.size.width - 0.75)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(
            "\(FleetDisplay.shown(pct, remaining: remaining))"
                + " percent \(FleetDisplay.axisWord(remaining: remaining))"
        )
    }
}
