import AppKit
import SwiftUI

/// The CLAUDE page's exception surface (CBAR4-4, design §3.10), priority-ordered so
/// exceptional truth always appears in the same place: dead-daemon banner > switch
/// lifecycle > wrap-off card > zero-armed warning > forecast sentence. TABS-1: the
/// lifecycle row renders here only for a CLAUDE-harness switch — a codex switch's
/// lifecycle lives on the Codex page's strip (no cross-tab bleed, no wrong-active
/// wording).
struct StatusStrip: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if isDead {
                DeadDaemonBanner(model: model)
            } else if model.switchPhase != .idle, model.switchHarness == .claude {
                SwitchLifecycleRow(phase: model.switchPhase, currentName: model.active?.name)
            } else if isWrapOff {
                wrapOffCard
            } else if model.autoSwitchIdle {
                zeroArmed
            } else if let sentence = model.forecastSentence {
                forecast(sentence)
            }
        }
        .padding(.horizontal, 19).padding(.top, 5).padding(.bottom, 10)
    }

    // Dead = a frozen-but-present status (stalled); a never-written file is the
    // panel's empty state, handled a level up.
    private var isDead: Bool { model.liveness.isStalled }
    private var isWrapOff: Bool { (model.status?.activeProfile == nil) && model.status != nil }

    // MARK: - Wrap-off card (§3.15)

    private var wrapOffCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "powersleep").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("All accounts switched off — chain spent.").font(Theme.meta)
                if let eta = model.wrapOffResumeETA {
                    Text("Auto-resumes when a window \(eta.replacingOccurrences(of: "resets in", with: "resets in ≤"))")
                        .font(Theme.sub).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Zero-armed warning (§3.16)

    private var zeroArmed: some View {
        let chainEmpty = model.status?.fallbackChain.isEmpty ?? true
        return HStack(spacing: 10) {
            Image(systemName: "bolt.slash.fill").foregroundStyle(Theme.warning)
            if chainEmpty {
                Text("Auto-switch off — no fallback chain.").font(Theme.meta)
                Spacer(minLength: 0)
                Button { model.showConfig = true } label: {
                    Text("Set up").font(Theme.sub).fontWeight(.medium).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text("Auto-switch idle — \(model.active?.name ?? "the active account") isn't armed.")
                    .font(Theme.meta)
                Spacer(minLength: 0)
                if let name = model.active?.name {
                    Button { model.fallbackAdd(name) } label: {
                        Text("Add \(name)").font(Theme.sub).fontWeight(.medium).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Forecast sentence (§3.11)

    private func forecast(_ sentence: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(Theme.sapphire)
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence).font(Theme.meta).fixedSize(horizontal: false, vertical: true)
                Text(model.livenessStamp).font(Theme.sub).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared strip pieces (TABS-1 — used by StatusStrip AND CodexStrip)

/// The dead-daemon banner (§3.12/§3.13): shown on WHICHEVER page is open — a dead
/// daemon is machine truth, not a per-harness state.
struct DeadDaemonBanner: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Theme.danger).frame(width: 4).cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 5) {
                Text("Daemon not responding — data frozen \(model.frozenAge)")
                    .font(Theme.body).fontWeight(.semibold)
                Text("Auto-switch is NOT running.")
                    .font(Theme.sub).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Start daemon") { model.startDaemon() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Text("clauth daemon").font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("clauth daemon", forType: .string)
                    } label: { Image(systemName: "doc.on.doc").foregroundStyle(.secondary) }
                        // `.plain`, not `.borderless`: borderless chrome draws the □
                        // missing-image box under headless ImageRenderer (--snapshot).
                        .buttonStyle(.plain).help("Copy command")
                }
            }
        }
    }
}

/// The switch lifecycle row (§2 STATE 3), harness-agnostic: the caller passes the
/// harness-matched current active so the arming copy names the right account.
struct SwitchLifecycleRow: View {
    let phase: SwitchMachine.Phase
    let currentName: String?

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .arming(let target):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
                Text("Confirm — live session on \(currentName ?? "current"); switching to \(target)")
                    .font(Theme.meta).foregroundStyle(.primary)
            case .pending(let target):
                ProgressView().controlSize(.small)
                Text("Switching to \(target)…").font(Theme.meta)
            case .confirmed(let target, let viaCLI):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(viaCLI ? "Switched to \(target) via CLI — auto-switch inactive until daemon starts"
                            : "Switched to \(target)")
                    .font(Theme.meta)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(reason).font(Theme.meta).fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }
}
