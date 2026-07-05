import AppKit
import SwiftUI

/// The menu-bar dropdown, hosted in `MenuBarExtra(.window)`. A translucent panel:
/// account switcher → active account's usage (Session / Weekly / Fable) → the
/// fallback chain → a Configure disclosure → actions. Data comes from
/// `status.json` via `StatusModel`; edits go to the daemon socket.
struct PanelView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A command error is orthogonal to liveness — surface it above everything
            // so a rejected tap is never silent (TECH-11).
            if let error = model.lastCommandError {
                commandErrorBanner(error)
            }
            switch model.liveness {
            case .down:
                emptyState
            case .outOfDate(let schema):
                outOfDateState(schema)
            case .ok:
                if let status = model.status { content(status) } else { emptyState }
            case .stalled(let since):
                if let status = model.status {
                    stalledBanner(since)
                    content(status)
                } else {
                    emptyState
                }
            }
        }
        .frame(width: 320)
        .padding(.vertical, 12)
    }

    // MARK: - Command-outcome banner (TECH-11)

    /// A transient toast for the last command's error (a daemon rejection or an
    /// unreachable daemon). Auto-clears; the model owns the timing.
    private func commandErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
            Text(message).font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: - Liveness banners (TECH-4)

    /// The daemon wrote this file then died: the numbers below are frozen, not
    /// live. A loud banner over the (last-known) content so a stale % never reads
    /// as current.
    private func stalledBanner(_ since: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("Daemon stalled — data from \(since)").font(.caption).fontWeight(.semibold)
                Text("Restart with `clauth daemon`").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    /// The daemon's status.json is a schema this clauthbar doesn't understand —
    /// update clauthbar, don't debug launchd. Distinct from the daemon-down state.
    private func outOfDateState(_ schema: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("clauthbar out of date", systemImage: "arrow.up.circle")
                .font(.subheadline).foregroundStyle(Theme.warning)
            Text("The daemon writes status.json schema \(schema); this clauthbar reads \(supportedSchema). Update clauthbar.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            ActionRow(icon: "power", title: "Quit clauthbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Populated panel

    @ViewBuilder
    private func content(_ status: DaemonStatus) -> some View {
        switcher(status)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

        if let active = model.active {
            Divider().padding(.horizontal, 12).padding(.vertical, 8)
            header(active)
            usage(active).padding(.top, 10)
        }

        Divider().padding(.horizontal, 12).padding(.vertical, 10)
        chainSection(status)

        Divider().padding(.horizontal, 12).padding(.vertical, 10)
        ConfigView(model: model, status: status).padding(.horizontal, 16)

        footerMeta(status)

        Divider().padding(.horizontal, 12).padding(.vertical, 8)
        actions
    }

    // MARK: - Account switcher (the hero — switching is the point)

    private func switcher(_ status: DaemonStatus) -> some View {
        HStack(spacing: 8) {
            ForEach(model.orderedProfiles) { p in
                // Disable every tile while a switch is in flight so a double-tap
                // can't fire two concurrent switches (M5/TECH-11).
                AccountTile(p: p, disabled: model.switchInFlight) { model.switchTo(p.name) }
            }
        }
    }

    // MARK: - Active account header

    private func header(_ p: ProfileStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(p.name).font(.title2).bold()
            if p.isStale {
                Text("· \(p.fetchStatus ?? "stale")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let tier = p.tier {
                Text(tier).font(.subheadline).foregroundStyle(.secondary)
            } else if p.provider != "anthropic" {
                Text(p.provider).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Usage sections

    @ViewBuilder
    private func usage(_ p: ProfileStatus) -> some View {
        if p.provider != "anthropic" {
            // Third-party / api-key: the daemon only reports up/down, no windows.
            availabilityRow(p).padding(.horizontal, 16)
        } else {
            VStack(spacing: 14) {
                UsageRow(label: "Session", window: p.fiveHour, threshold: p.fallback?.threshold)
                UsageRow(label: "Weekly", window: p.sevenDay, threshold: nil)
                UsageRow(label: "Fable", window: p.fableWeek, threshold: nil)
            }
            .padding(.horizontal, 16)
        }
    }

    private func availabilityRow(_ p: ProfileStatus) -> some View {
        let available = p.thirdParty?.available
        let (text, color): (String, Color) = {
            switch available {
            case .some(true): return ("Available", Theme.success)
            case .some(false): return ("Unavailable", Theme.danger)
            case .none: return ("No data yet", .secondary)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Fallback chain (the signature element)

    private func chainSection(_ status: DaemonStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fallback chain").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(status.wrapOff ? "wrap-off on" : "stay on last")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if status.fallbackChain.isEmpty {
                Text("None — add accounts below")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ChainStrip(status: status)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Footer meta (last switch + version skew) — TECH-11

    /// A quiet footer: the last executed switch (so the hero event is visible, not
    /// buried in daemon.log) and a soft version-skew badge when the daemon's clauth
    /// version differs from what this clauthbar targets.
    @ViewBuilder
    private func footerMeta(_ status: DaemonStatus) -> some View {
        let skew = model.versionSkew
        if status.lastSwitch != nil || skew != nil {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.vertical, 8)
                if let ls = status.lastSwitch {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(lastSwitchText(ls)).font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                if let daemonVersion = skew {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.circle").font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                        Text("daemon clauth \(daemonVersion); clauthbar targets \(StatusModel.expectedClauthVersion)")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// "switched work → home · 2m ago (auto)" — coarse, quiet.
    private func lastSwitchText(_ ls: LastSwitch) -> String {
        let target = ls.to ?? "off"
        let arrow = ls.from.map { "\($0) → \(target)" } ?? target
        let via = ls.trigger == "user" ? "" : " (\(ls.trigger))"
        if let when = Theme.parseISO(ls.at) {
            let ago = agoText(Int(Date().timeIntervalSince(when)))
            return "switched \(arrow) · \(ago)\(via)"
        }
        return "switched \(arrow)\(via)"
    }

    /// Coarse "N{m,h,d} ago" from a positive second count.
    private func agoText(_ secs: Int) -> String {
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86_400)d ago"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 1) {
            ActionRow(icon: "arrow.clockwise", title: "Refresh now") { model.refresh() }
            // Autostart opt-out (TECH-14 #42) — only in the packaged .app, where
            // SMAppService can register; a no-op toggle in `swift run` would mislead.
            if LoginItem.isAvailable {
                Toggle(isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { LoginItem.setEnabled($0) }
                )) {
                    HStack(spacing: 8) {
                        Image(systemName: "power.circle").frame(width: 16)
                        Text("Start at login")
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.vertical, 5).padding(.horizontal, 8)
            }
            ActionRow(icon: "power", title: "Quit clauthbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("clauth daemon not running", systemImage: "moon.zzz")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Start it with `clauth daemon` (or the LaunchAgent), then reopen.")
                .font(.caption).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 6)
            ActionRow(icon: "power", title: "Quit clauthbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Components

/// A switchable account tile: name, active state, a tiny 5h meter. Filled with
/// the accent when active; tap to switch the global account.
private struct AccountTile: View {
    let p: ProfileStatus
    var disabled: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                // FLOOR RULE (§4): names ≥ 13pt, never auto-shrunk — overflow
                // truncates with tail + .help (the button already carries .help).
                Text(p.name)
                    .font(.body).fontWeight(p.active ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.tail)
                UsageBar(
                    pct: p.fiveHourPct,
                    color: p.active ? Color.white.opacity(0.9) : Theme.usageColor(p.fiveHourPct, threshold: p.fallback?.threshold ?? 100),
                    height: 3,
                    threshold: p.fallback?.threshold
                )
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                p.active ? Theme.accent : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .foregroundStyle(p.active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !p.active ? 0.5 : 1)
        .help(p.active ? "Active account" : "Switch to \(p.name)")
    }
}

/// One usage window: bold label, a thin bar, then `X% used` / `resets in …`.
private struct UsageRow: View {
    let label: String
    let window: UsageWindow?
    let threshold: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).fontWeight(.semibold)
            if let w = window {
                UsageBar(pct: w.utilizationPct, color: Theme.usageColor(w.utilizationPct, threshold: threshold ?? 100), threshold: threshold)
                HStack {
                    Text("\(Int(w.utilizationPct.rounded()))% used")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if let hint = Theme.resetHint(w.resetsAt) {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                UsageBar(pct: 0, color: Theme.track)
                Text("no data yet").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The fallback chain as capsule chips joined by arrows; the armed member (the
/// one auto-switch would rotate away from) glows in the accent.
private struct ChainStrip: View {
    let status: DaemonStatus

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(status.fallbackChain.enumerated()), id: \.offset) { i, name in
                if i > 0 {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                }
                chip(for: name)
            }
        }
    }

    private func chip(for name: String) -> some View {
        let fb = status.profiles.first { $0.name == name }?.fallback
        let armed = fb?.armed ?? false
        return HStack(spacing: 4) {
            if armed { Image(systemName: "bolt.fill").font(.system(size: 9)) }
            Text(name).font(.caption).fontWeight(armed ? .semibold : .regular)
            Text("\(Int(fb?.threshold ?? 95))%")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(
            armed ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05),
            in: Capsule()
        )
        .foregroundStyle(armed ? Theme.accent : Color.primary)
    }
}

/// A full-width action row: SF Symbol + title, with a hover highlight.
struct ActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                hovering ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
