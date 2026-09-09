import AppKit
import SwiftUI

/// The menu-bar dropdown, hosted in `MenuBarExtra(.window)`. Since TABS-1 the
/// panel is a tab ROUTER (codexbar-style): global banners → the provider tab bar
/// (Overview / Claude / Codex) → the selected page → the shared actions rows.
/// The per-harness pages keep the CBAR-4 "Preflight" anatomy (design §2): strip →
/// account LIST (inspect-first) → detail card → chain rail → config disclosure.
/// Data comes from `status.json` via `StatusModel`; edits go to the socket.
struct PanelView: View {
    /// The menu-bar figure knobs (FLEET-1). `@AppStorage` in a View, never in
    /// an `ObservableObject` — see `FleetDisplay`.
    @AppStorage(FleetDisplay.barsKey) private var fleetShowsBars = false
    @AppStorage(FleetDisplay.remainingKey) private var fleetShowsRemaining = false
    @AppStorage(FleetDisplay.activeOnlyKey) private var fleetShowsActiveOnly = false
    @AppStorage(FleetDisplay.disarmedKey) private var fleetShowsDisarmed = true
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.liveness {
            case .outOfDate(let schema):
                outOfDateState(schema)
            case .down:
                emptyState
            case .ok, .stalled:
                if let status = model.status { populated(status) } else { emptyState }
            }
        }
        .frame(width: 420)
        .padding(.vertical, 14)
        .onAppear { if !model.isPreview { model.resetInspection() } }
    }

    // MARK: - Populated panel: banners → tab bar → page → actions

    @ViewBuilder
    private func populated(_ status: DaemonStatus) -> some View {
        let dead = model.liveness.isStalled
        // Global banners: model-wide states that must be visible from ANY page —
        // a rejected config edit, the armed-member removal confirm, an in-flight
        // login, and the rename/add editors (TextFields need a stable focus home).
        if let error = model.lastCommandError {
            commandErrorBanner(error)
        }
        if let prompt = model.pendingRemovalPrompt {
            removalConfirmBanner(prompt)
        }
        if let prompt = model.pendingDeletePrompt {
            deleteConfirmBanner(prompt)
        }
        if let flight = model.loginInFlight {
            LoginFlightBanner(flight: flight)
        }
        if let name = model.renaming {
            RenameBanner(model: model, name: name)
        }
        if let harness = model.addingHarness {
            AddAccountBanner(model: model, harness: harness)
        }
        if let name = model.settingSetupToken {
            SetupTokenBanner(model: model, name: name)
        }
        ProviderTabBar(model: model)
        Divider().padding(.horizontal, 14).padding(.top, 7)
        switch model.tab {
        case .overview:
            OverviewPage(model: model, status: status, dead: dead)
        case .claude:
            claudePage(status, dead: dead)
        case .codex:
            codexPage(status, dead: dead)
        }
        if let skew = model.versionSkew {
            Text("daemon clauth \(skew); ccsbar targets \(StatusModel.expectedClauthVersion)")
                .font(Theme.micro).foregroundStyle(.secondary)
                .padding(.horizontal, 19).padding(.top, 7)
        }
        Divider().padding(.horizontal, 14).padding(.vertical, 10)
        actions(dead: dead)
    }

    // MARK: - Claude page (the pre-TABS-1 panel body, harness-scoped)

    @ViewBuilder
    private func claudePage(_ status: DaemonStatus, dead: Bool) -> some View {
        // Machine-wide Claude Code token usage (TOK-4) — ambient context ABOVE the
        // per-account strip. tokens.json is CLAUDE CODE telemetry, so the strip
        // lives on this page, not Overview. Present only when a snapshot exists
        // (startExpanded pins the hover-only detail open for headless snapshot
        // media, which can't hover).
        if model.machineTokens != nil {
            TokensStrip(model: model, startExpanded: model.isPreview)
            Divider().padding(.horizontal, 14)
        }
        StatusStrip(model: model)
        Divider().padding(.horizontal, 14)
        harnessBody(status, harness: .claude, dead: dead)
    }

    // MARK: - Codex page (TABS-1)

    @ViewBuilder
    private func codexPage(_ status: DaemonStatus, dead: Bool) -> some View {
        CodexStrip(model: model)
        // PROXY-1: local-file/state row — independent of daemon liveness, so
        // it renders (and works) even on a dead-daemon page.
        CodexProxyRow().padding(.horizontal, 10)
        Divider().padding(.horizontal, 14)
        harnessBody(status, harness: .codex, dead: dead)
    }

    /// The shared page body below the strip: accounts → detail → chain → config.
    /// With ZERO profiles on this harness, the accounts section's first-run door
    /// owns the whole page — a chain rail pointing at an empty Configure would be
    /// a dead-end hint, so it (and the disclosure) render only once accounts exist.
    @ViewBuilder
    private func harnessBody(_ status: DaemonStatus, harness: Harness, dead: Bool) -> some View {
        AccountsSection(model: model, status: status, harness: harness, dead: dead)
        if let inspected = model.inspected, inspected.harnessKind == harness {
            Divider().padding(.horizontal, 14).padding(.vertical, 7)
            DetailCard(model: model, p: inspected, dead: dead)
        }
        if !model.profiles(for: harness).isEmpty {
            Divider().padding(.horizontal, 14).padding(.vertical, 10)
            ChainRail(model: model, status: status, harness: harness, dead: dead)
            if model.showConfig {
                ConfigView(model: model, status: status, harness: harness)
                    .padding(.horizontal, 19).padding(.top, 7)
            }
        }
    }

    // MARK: - Actions (§2 — 24pt rows, shared across pages)

    private func actions(dead: Bool) -> some View {
        VStack(spacing: 1) {
            ActionRow(icon: "arrow.clockwise", title: "Refresh usage") { model.refresh() }
                .disabled(dead)
                .keyboardShortcut("r", modifiers: [])
            // FLEET-1 menu-bar knobs. They live beside "Start at login" because
            // that is where the app's own (not an account's) preferences are,
            // and both change what the MENU BAR shows rather than this panel.
            PanelSwitchToggle(isOn: $fleetShowsDisarmed) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.slash").frame(width: 19)
                    Text("Menu bar shows disarmed mark"); Spacer()
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .help("Mark the menu bar when no chain will rotate. Off hides it — the chain stays disarmed either way.")
            PanelSwitchToggle(isOn: $fleetShowsActiveOnly) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle").frame(width: 19)
                    Text("Menu bar shows active account"); Spacer()
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .help("Read each harness's active account instead of averaging its whole pool.")
            PanelSwitchToggle(isOn: $fleetShowsRemaining) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right.circle").frame(width: 19)
                    Text("Menu bar shows remaining"); Spacer()
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .help("Show what is LEFT of the weekly window instead of what is spent.")
            PanelSwitchToggle(isOn: $fleetShowsBars) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar").frame(width: 19)
                    Text("Menu bar shows bars"); Spacer()
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .help("Draw a small usage bar beside each harness figure in the menu bar.")
            if LoginItem.isAvailable {
                PanelSwitchToggle(isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })) {
                    HStack(spacing: 10) {
                        Image(systemName: "power.circle").frame(width: 19)
                        Text("Start at login"); Spacer()
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
            }
            ActionRow(icon: "power", title: "Quit ccsbar · daemon keeps running") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .help("The clauth daemon keeps running — auto-switch continues.")
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Armed-member removal confirm (§7)

    private func removalConfirmBanner(_ prompt: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(prompt).font(Theme.sub).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Cancel is pure local state — never gated on daemon reachability.
            Button("Cancel") { model.cancelRemoval() }.controlSize(.small)
            Button("Remove") { model.confirmRemoval() }.controlSize(.small).tint(Theme.danger)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14).padding(.bottom, 7)
    }

    // MARK: - Profile-delete confirm (danger tint — this one destroys credentials)

    private func deleteConfirmBanner(_ prompt: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill").foregroundStyle(Theme.danger)
            Text(prompt).font(Theme.sub).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Cancel is pure local state — never gated on daemon reachability.
            Button("Cancel") { model.cancelDelete() }.controlSize(.small)
            // Same gate as `confirmDelete`'s login guard, made VISIBLE: an
            // enabled button whose tap silently no-ops reads as broken, and
            // a login can hold the guard for its whole browser wait.
            Button("Delete") { model.confirmDelete() }
                .controlSize(.small).tint(Theme.danger)
                .disabled(model.loginInFlight != nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14).padding(.bottom, 7)
    }

    // MARK: - Config-command error banner (TECH-11)

    private func commandErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
            Text(message).font(Theme.fine).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14).padding(.bottom, 7)
    }

    // MARK: - Empty / out-of-date states

    private func outOfDateState(_ schema: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("ccsbar out of date", systemImage: "arrow.up.circle")
                .font(Theme.sub).foregroundStyle(Theme.warning)
            Text("The daemon writes status.json schema \(schema); this ccsbar reads \(supportedSchema). Update ccsbar.")
                .font(Theme.fine).foregroundStyle(.secondary)
            Divider().padding(.vertical, 7)
            ActionRow(icon: "power", title: "Quit ccsbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 19)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("clauth daemon not running", systemImage: "moon.zzz")
                .font(Theme.sub).foregroundStyle(.secondary)
            Text("Start it with `clauth daemon` (or the LaunchAgent), then reopen.")
                .font(Theme.fine).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 7)
            ActionRow(icon: "power", title: "Quit ccsbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 19)
    }
}

// MARK: - Action row

/// A full-width action row: SF Symbol + title, with a hover highlight.
struct ActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 19)
                Text(title).font(Theme.body).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
