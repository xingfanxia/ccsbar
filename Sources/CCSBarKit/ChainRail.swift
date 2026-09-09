import SwiftUI

/// The CHAIN section (design §2), extracted from PanelView and harness-scoped
/// (TABS-1): header + Edit toggle, the chain as capsule chips joined by arrows,
/// and the one-line when-spent summary. Each provider page renders its own
/// harness's chain; the copy differs because the OUTCOMES differ — claude has the
/// wrap-off choice, codex rotates at session boundaries and has no wrap-off.
struct ChainRail: View {
    @ObservedObject var model: StatusModel
    let status: DaemonStatus
    let harness: Harness
    let dead: Bool

    private var chain: [String] { status.chain(for: harness) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHAIN").font(Theme.sub).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                // A `.plain` text button, NOT `.buttonStyle(.borderless)`: the AppKit
                // borderless chrome fails to rasterize under headless `ImageRenderer`
                // (draws the missing-image □ in --snapshot media); a styled Text label
                // renders identically in the live app and the snapshot.
                Button { model.showConfig.toggle() } label: {
                    Text("Edit").font(Theme.sub).fontWeight(.medium).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).disabled(dead)
            }
            if chain.isEmpty {
                Text("None — add accounts in Configure").font(Theme.fine).foregroundStyle(.secondary)
            } else {
                ChainStrip(status: status, chain: chain)
                Text(harness == .codex
                     ? ChainEdit.codexWhenSpentSummary
                     : ChainEdit.whenSpentSummary(wrapOff: status.wrapOff))
                    .font(Theme.fine).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 19)
        .opacity(dead ? 0.6 : 1)
    }
}

/// The fallback chain as capsule chips joined by arrows; the armed member glows in
/// sapphire (armed = auto-switch is watching it). Chain order comes from the
/// caller's harness-matched name array; per-member truth (armed/threshold) comes
/// off the profile's own `fallback` block, which the daemon computes against that
/// same harness's chain.
struct ChainStrip: View {
    let status: DaemonStatus
    let chain: [String]

    var body: some View {
        // Wrap onto another line for 3+ member chains — a plain HStack overflows the
        // fixed-width panel and makes each chip wrap its OWN text ("ac-count-1"). Each
        // item bundles its leading arrow so a wrapped chip carries its "→" with it.
        FlowLayout(spacing: 7, lineSpacing: 6) {
            ForEach(Array(chain.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 7) {
                    if i > 0 {
                        Image(systemName: "arrow.right").font(Theme.micro).foregroundStyle(.tertiary)
                    }
                    chip(for: name)
                }
                .fixedSize()
            }
        }
    }

    private func chip(for name: String) -> some View {
        let fb = status.profiles.first { $0.name == name }?.fallback
        let armed = fb?.armed ?? false
        return HStack(spacing: 5) {
            if armed { Image(systemName: "bolt.fill").font(.system(size: 11)) }
            Text(name).font(Theme.meta).fontWeight(armed ? .semibold : .regular).lineLimit(1)
            Text("@\(Int(fb?.threshold ?? 95))")
                .font(Theme.micro).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4).padding(.horizontal, 10)
        .background(armed ? Theme.sapphire.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
        .foregroundStyle(armed ? Theme.sapphire : Color.primary)
    }
}
