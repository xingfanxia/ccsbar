import SwiftUI

/// The ACCOUNTS list for one harness page (design §2, harness-scoped by TABS-1):
/// header, that harness's rows in stable file order, the add-account door, and
/// ↑/↓ inspection. The harness pill on rows is hidden here — the tab already
/// scopes the list, so the pill would be noise.
struct AccountsSection: View {
    @ObservedObject var model: StatusModel
    let status: DaemonStatus
    let harness: Harness
    let dead: Bool

    /// Whether the inactive-plan group is expanded. Persisted (shared across
    /// both harness pages on purpose — "show me the dead weight" is one
    /// preference, not two), default collapsed.
    @AppStorage("showInactiveAccounts") private var showInactive = false

    private var profiles: [ProfileStatus] { model.profiles(for: harness) }

    /// The split that drives the collapse: an account on a cancelled/lapsed
    /// plan (`planInactive`) folds into the collapsed group — EXCEPT the
    /// active account, which is never hidden whatever its plan is worth
    /// (hiding what you're running on would be the panel lying). Static and
    /// pure so the exclusion rule is unit-tested without a view.
    static func partition(_ profiles: [ProfileStatus])
        -> (current: [ProfileStatus], inactive: [ProfileStatus])
    {
        let inactive = profiles.filter { $0.planInactive && !$0.active }
        let current = profiles.filter { !($0.planInactive && !$0.active) }
        return (current, inactive)
    }

    private var inactive: [ProfileStatus] { Self.partition(profiles).inactive }
    private var current: [ProfileStatus] { Self.partition(profiles).current }
    /// The rows actually rendered, in stable file order within each half.
    private var displayed: [ProfileStatus] { showInactive ? current + inactive : current }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ACCOUNTS")
                .font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 4)
            if profiles.isEmpty {
                emptyState.padding(.horizontal, 16).padding(.vertical, 6)
            } else {
                let rows = ForEach(displayed) { p in
                    AccountRow(
                        model: model,
                        p: p,
                        status: status,
                        inspected: model.isInspected(p.name),
                        dead: dead,
                        frozenStamp: dead ? "as of \(model.frozenAge)" : nil,
                        showHarnessTag: false,
                        onInspect: { model.inspect(p.name) }
                    )
                    .padding(.horizontal, 8)
                }
                if displayed.count > 6 {
                    ScrollView { VStack(spacing: 2) { rows } }.frame(maxHeight: 340)
                } else {
                    rows
                }
                if !inactive.isEmpty {
                    InactiveAccountsToggle(
                        count: inactive.count,
                        expanded: showInactive,
                        action: { showInactive.toggle() }
                    )
                    .padding(.horizontal, 8)
                }
            }
            // Sign a BRAND-NEW account in, in-app (design §7). Subdued below the
            // rows; disabled only while a login is already in flight (single-login
            // guard). Deliberately NOT gated on a dead/frozen panel: the login is a
            // pure CLI flow that works with the daemon down (same policy as the
            // reauth button), and the newcomer surfaces on the next tick once the
            // daemon is back.
            AddAccountRow(
                title: harness == .codex ? "Add codex account…" : "Add account…",
                disabled: model.loginInFlight != nil,
                action: { model.beginAddAccount(harness) }
            )
            .padding(.horizontal, 8)
        }
        // ↑/↓ move inspection (macOS 14 focus nav; degrades gracefully).
        .focusable()
        .onMoveCommand { direction in moveInspection(direction) }
    }

    /// The first-run door (TABS-1): an empty list is an invitation, not a dead end.
    /// The codex copy names BOTH ways in — capture (instant, no browser: codex is
    /// usually already signed in on this machine) and a fresh browser sign-in; the
    /// add editor below offers the same two verbs.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(harness == .codex ? "No codex accounts yet." : "No Claude accounts yet.")
                .font(.callout).fontWeight(.medium)
            Text(harness == .codex
                 ? "Capture the login codex is already signed in with — instant — or sign in fresh in a browser."
                 : "Sign in with your browser to create the first profile.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func moveInspection(_ direction: MoveCommandDirection) {
        // Navigate the VISIBLE rows — arrowing into a collapsed account would
        // move the inspection onto a row that isn't on screen.
        let names = displayed.map(\.name)
        guard !names.isEmpty else { return }
        let current = model.inspected?.name ?? names[0]
        guard let i = names.firstIndex(of: current) else { return }
        switch direction {
        case .up: model.inspect(names[max(0, i - 1)])
        case .down: model.inspect(names[min(names.count - 1, i + 1)])
        default: break
        }
    }
}

/// The collapsed-group toggle row: "N inactive plans" with a disclosure
/// chevron, quieter than an AccountRow (the whole point is getting dead weight
/// out of the eye line). The count keeps the group honest while collapsed —
/// accounts are folded away, never unlisted.
struct InactiveAccountsToggle: View {
    let count: Int
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var title: String {
        let noun = count == 1 ? "account" : "accounts"
        return expanded
            ? "Hide inactive \(noun)"
            : "\(count) inactive \(noun) (canceled / free)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 16)
                Text(title).font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The subdued "⊕ Add account…" row at the foot of the ACCOUNTS list — deliberately
/// quieter than an AccountRow (secondary tint, no usage bar, smaller type). Clicking
/// opens the inline add-account editor. Dimmed + inert while `disabled`.
struct AddAccountRow: View {
    let title: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.callout)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && !disabled ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}
