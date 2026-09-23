import SwiftUI

/// The machine-wide token-usage strip (TOK-4) — Claude Code's LOCAL usage across ALL
/// accounts on this machine, fed by `~/.clauth/tokens.json`. It sits ABOVE the
/// per-account content as ambient machine context, so it is deliberately NEUTRAL:
/// secondary/tertiary tones only, never terracotta (ACTIVE) or sapphire (ARMED) —
/// those hues carry per-account meaning the §5 palette reserves.
///
/// Every count is the CACHE-INCLUSIVE `displayTokens` (with a `+` floor marker when
/// a window's buckets undercount), so the token figure tracks the dollar figure
/// beside it — cost always prices cache tokens, and the cache-excluded `in_out`
/// basis this strip originally headlined read as a broken counter ("1.03M · $319").
///
/// Collapsed to ONE line ("today 577M · $12.40"); CLICKING that line expands an
/// inline detail block (a 4-row period table + the top models) in place, the same
/// disclosure idiom the banners use — no popover. It used to open on hover, which
/// resized the whole panel whenever the pointer merely crossed the strip; now only
/// a click changes the layout, hover just highlights, and the choice is remembered
/// across panel opens. Rendered only when `machineTokens != nil`; PanelView also
/// gates the surrounding divider on that, so a machine with no snapshot yet shows no
/// trace of the strip.
struct TokensStrip: View {
    @ObservedObject var model: StatusModel
    /// Remembered across panel opens, like the panel's display options.
    @AppStorage("tokensStripExpanded") private var expandedPref = false
    @State private var hovering = false
    /// True only for snapshot/preview renders, which show the detail regardless
    /// of the viewer's remembered choice so the media is deterministic.
    private let pinnedOpen: Bool

    init(model: StatusModel, startExpanded: Bool = false) {
        self.model = model
        self.pinnedOpen = startExpanded
    }

    private var expanded: Bool { pinnedOpen || expandedPref }

    var body: some View {
        if let tokens = model.machineTokens {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expandedPref.toggle() }
                } label: {
                    collapsedLine(tokens)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .background(hovering ? Color.primary.opacity(0.045) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel(expanded ? "Hide token details" : "Show token details")
                if expanded { detail(tokens).padding(.horizontal, 6) }
            }
            .padding(.horizontal, 13).padding(.top, 2).padding(.bottom, 10)
        }
    }

    // MARK: - Collapsed line

    private func collapsedLine(_ t: MachineTokens) -> some View {
        let today = t.periods.today
        return HStack(spacing: 7) {
            Image(systemName: "chart.bar.xaxis").font(Theme.fine).foregroundStyle(.secondary)
            Text("Tokens").font(Theme.fine).fontWeight(.medium).foregroundStyle(.secondary)
            Text("today \(MachineTokens.formatCount(today.displayTokens, isFloor: !today.complete)) · \(MachineTokens.formatCost(today.costUsd, isFloor: today.costIsFloor))")
                .font(Theme.fine).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Expanded detail (period table + top models)

    private func detail(_ t: MachineTokens) -> some View {
        let top = t.modelsPeriod.topModels(3)
        return VStack(alignment: .leading, spacing: 7) {
            periodRow("TODAY", t.periods.today)
            periodRow("WEEK", t.periods.week)
            periodRow("MONTH", t.periods.month)
            periodRow("LIFETIME", t.periods.lifetime)
            if !top.isEmpty {
                Divider().padding(.vertical, 1)
                Text("TOP MODELS · \(t.modelsBasis.rawValue)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(top) { modelRow($0) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Neutral wash (not a colored banner tint) — this is machine context, not an
        // alert; the primary-based fill reads as a quiet card in light and dark.
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func periodRow(_ label: String, _ p: TokenPeriod) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.micro).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(MachineTokens.formatCount(p.displayTokens, isFloor: !p.complete))
                .font(Theme.fine).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(MachineTokens.formatCost(p.costUsd, isFloor: p.costIsFloor))
                .font(Theme.fine).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
    }

    private func modelRow(_ m: TokenModel) -> some View {
        HStack(spacing: 10) {
            Text(m.display).font(Theme.micro).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(MachineTokens.formatCount(m.displayTokens, isFloor: !m.splitComplete))
                .font(Theme.micro).monospacedDigit().foregroundStyle(.tertiary)
            Text(MachineTokens.formatCost(m.costUsd))
                .font(Theme.micro).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 65, alignment: .trailing)
        }
    }
}
