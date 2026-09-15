import SwiftUI

/// What the inspected account's ROW cannot say, plus the verb that acts on it.
///
/// This used to be a full card: the name and tier again, the email again, every
/// window as a labelled bar with its percentage and reset again. All of it sits
/// in the row two inches above, and the panel opens with the ACTIVE account
/// inspected — so at rest the card was a second, taller rendering of the row
/// already highlighted in the list (AX, 2026-09-14: 「那两块显示当前active
/// account的信息呈现很重复 · 和上面account list展示的信息重复」).
///
/// So it carries only what is NOT in the list: the session-token horizon, the
/// chain-membership sentence, a live isolated session, a third-party host, and
/// the switch or re-login verb. Freshness went too — the status strip at the top
/// of the page already stamps it. When the inspected account is active and
/// healthy there is no verb, and if it also has nothing unique to report the
/// card renders NOTHING, divider included.
struct DetailCard: View {
    @ObservedObject var model: StatusModel
    let p: ProfileStatus
    let dead: Bool

    /// Whether this card has anything to say. Drives the divider too — a rule
    /// above an empty region is worse than no region.
    var isEmpty: Bool {
        Self.isEmpty(
            hasVerb: hasVerb,
            hasTokenLine: tokenLine != nil,
            hasChainLine: model.chainLine(for: p) != nil,
            hasLiveSession: p.hasLiveSession,
            hasThirdPartyHost: thirdPartyHost != nil
        )
    }

    /// The emptiness rule, as a pure function of the five things the card can
    /// carry. Split out so it is testable without a view — the panel has no
    /// render test, and the one thing that must never regress here is a divider
    /// drawn over nothing.
    nonisolated static func isEmpty(
        hasVerb: Bool,
        hasTokenLine: Bool,
        hasChainLine: Bool,
        hasLiveSession: Bool,
        hasThirdPartyHost: Bool
    ) -> Bool {
        !hasVerb && !hasTokenLine && !hasChainLine && !hasLiveSession && !hasThirdPartyHost
    }

    private var hasVerb: Bool {
        Self.showsVerb(
            active: p.active,
            authBroken: p.authBroken,
            canReauth: p.provider == "anthropic" || p.isCodex
        )
    }

    /// True when the card offers an action: a re-login for a broken account, or
    /// a switch for one that is not already active.
    ///
    /// The active, healthy account gets NOTHING. A disabled "Active account"
    /// button and a line telling you to pick another row were the loudest part
    /// of what AX called a duplicate of the list above. A broken login still
    /// outranks active-ness: an active account whose OAuth dropped is the most
    /// urgent re-login case, and it is the one account you cannot switch away
    /// from, so hiding its only fix would strand it.
    nonisolated static func showsVerb(active: Bool, authBroken: Bool, canReauth: Bool) -> Bool {
        if authBroken && canReauth { return true }
        return !active
    }

    private var thirdPartyHost: String? {
        p.provider == "anthropic" || p.isCodex ? nil : p.baseUrl
    }

    /// The session-token horizon, read from the sidecar per render.
    private var tokenLine: (text: String, tone: SessionToken.Tone)? {
        guard p.provider == "anthropic" else { return nil }
        return SessionToken.statusLine(
            SessionToken.state(profile: p.name),
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            fed: p.rollingToken
        )
    }

    var body: some View {
        if !isEmpty {
            Divider().padding(.horizontal, 14).padding(.vertical, 7)
            content.padding(.horizontal, 19)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // CLA-SPLIT: sessions on this account run on a static setup-token
            // mint — surface it and its ~1yr horizon (WARNING inside 30 days,
            // DANGER + re-mint hint once expired). Read from the sidecar per
            // render; nothing shows for profiles without one. CLA-ROLL: a
            // rolling-token profile (status.json `rolling_token`, legacy
            // `session_feed`) renders its hours-scale countdown as calm
            // maintenance instead.
            if let line = tokenLine {
                Text(line.text)
                    .font(Theme.fine)
                    .foregroundStyle(line.tone == .danger ? Theme.danger
                        : line.tone == .warning ? Theme.warning : .secondary)
                    .lineLimit(1)
            }
            // An isolated `clauth start` session is holding this login, which is
            // why a switch away from it can be refused. The row has no room for
            // it and it changes what the verb below will do.
            if p.hasLiveSession {
                Label("Live session attached", systemImage: "terminal")
                    .font(Theme.fine).foregroundStyle(.secondary)
            }
            // A third-party account's endpoint — the row reports whether it
            // answers, never WHICH host answered.
            if let host = thirdPartyHost {
                Text(host).font(Theme.fine).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let line = model.chainLine(for: p) {
                chainLine(line)
            }
            switchSurface
        }
    }

    private func chainLine(_ text: String) -> some View {
        // Flag for a last-resort member (matches its "last resort" copy), else the
        // sapphire bolt of a watched/rotating member — keyed on the explicit
        // `last_resort` flag, not threshold-100 (the two are independent now).
        let lastResort = p.fallback?.lastResort == true
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: lastResort ? "flag.fill" : "bolt.fill")
                .font(Theme.micro)
                .foregroundStyle(lastResort ? Color.secondary : Theme.sapphire)
            Text(text).font(Theme.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The one switch surface (§2 / §3.5-3.8)

    @ViewBuilder private var switchSurface: some View {
        // A broken login OUTRANKS the active-state readout: an ACTIVE account whose
        // OAuth dropped is the most urgent reauth case (the running claude sessions are
        // already failing on it), so the recovery verb must show even when p.active —
        // otherwise the one account you can't switch away from hides its only fix.
        // OAuth (anthropic) accounts renew via browser; codex profiles renew via the
        // codex PKCE browser flow (TABS-1). Third-party api-key profiles have no
        // login to renew — the daemon never marks them auth_broken, but guard anyway
        // so this surface and the context-menu item agree on who can reauth.
        if p.authBroken && (p.provider == "anthropic" || p.isCodex) {
            reauthSurface
        } else if !Self.showsVerb(active: p.active, authBroken: p.authBroken,
                                  canReauth: p.provider == "anthropic" || p.isCodex) {
            // Nothing. The row's ✓ already says active, and "pick another
            // account above" is advice nobody reads twice. Switching lives on
            // the row's own context menu as well as on every other row's verb.
            EmptyView()
        } else {
            // One button for both the live and offline paths so the arm-confirm cycle
            // works in BOTH: `switchTo` applies the live-session guard regardless of
            // daemon state (a CLI switch rewrites the Keychain too), and offline the
            // dispatch falls through to `clauth <name>`. Only the idle title differs.
            let offline = dead || !model.daemonReachable
            switchButton(idleTitle: offline ? "Switch via CLI (daemon offline)" : "Switch to \(p.name)")
        }
    }

    /// The harness's verb hue (TABS-1.1): codex blue for codex, the darkened
    /// terracotta for claude — white on #0A60FF is already AA (5.1:1), while
    /// plain terracotta needs `actVerb` to clear it under white button text.
    private var identityVerb: Color { p.isCodex ? Theme.codex : Theme.actVerb }

    /// AUTH-3: the account's login dropped (`auth_broken`). Instead of a dead-end
    /// "run clauth login" hint, offer a one-click browser reauth — it re-mints
    /// tokens and clears the flag (works daemon-up or -down). Shows an in-flight
    /// state while the browser sign-in runs. TABS-1: a codex profile recovers via
    /// the codex PKCE browser flow (`--codex --browser`); the context menu also
    /// offers the instant re-capture path.
    private var reauthSurface: some View {
        let inFlight = model.reauthInFlight == p.name
        let cli = p.isCodex ? "clauth login \(p.name) --codex --browser" : "clauth login \(p.name)"
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(Theme.sub).foregroundStyle(Theme.danger)
                Text("This account's login expired — re-authenticate to use it again.")
                    .font(Theme.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            Button {
                model.reauth(p.name, codex: p.isCodex)
            } label: {
                HStack {
                    Spacer()
                    if inFlight {
                        Text("Opening browser to sign in…")
                    } else {
                        Label("Log in again", systemImage: "person.crop.circle.badge.plus")
                    }
                    Spacer()
                }
                .font(Theme.body).fontWeight(.semibold).frame(height: 34).foregroundStyle(.white)
                .background(identityVerb.opacity(inFlight ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(model.reauthInFlight != nil)
            .help("Re-authenticate \(p.name) with a browser sign-in (runs `\(cli)`).")
        }
    }

    private func switchButton(idleTitle: String) -> some View {
        let target = p.name
        let (title, tint): (String, Color) = {
            switch model.switchPhase {
            case .arming(let t) where t == target:
                // Harness-matched current active (TABS-1): only claude arms today
                // (codex has no live-session signal), but the wording routes anyway.
                let current = model.activeProfile(for: p.harnessKind)?.name ?? "current"
                return ("Confirm — live session on \(current)", Theme.danger)
            case .pending(let t) where t == target:
                return ("Switching to \(target)…", identityVerb)
            default:
                return (idleTitle, identityVerb)
            }
        }()
        let pending: Bool = { if case .pending(let t) = model.switchPhase, t == target { return true }; return false }()
        return verbButton(title: title, tint: tint, disabled: pending || otherSwitchBusy(target)) {
            // A second tap while arming THIS target confirms; otherwise (re)start.
            if case .arming(let t) = model.switchPhase, t == target { model.confirmArmedSwitch() }
            else { model.switchTo(target) }
        }
    }

    /// True when a DIFFERENT switch is in flight — this target's button disables.
    private func otherSwitchBusy(_ target: String) -> Bool {
        guard let inFlight = model.switchPhase.inFlightTarget else { return false }
        return inFlight != target
    }

    private func verbButton(title: String, tint: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Spacer(); Text(title).font(Theme.body).fontWeight(.semibold); Spacer() }
                .frame(height: 34).foregroundStyle(.white)
                .background(tint.opacity(disabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(disabled)
        .keyboardShortcut(.return, modifiers: .command)
        // Name the real mechanism per harness (TABS-1). Codex must NOT claim it
        // affects running codex sessions: `clauth start` codex sessions run
        // isolated CODEX_HOMEs the shared-login rewrite can't strand.
        .help(p.isCodex
              ? "Rewrites ~/.codex/auth.json at the session boundary — isolated codex sessions (clauth start) are unaffected."
              : "Rewrites the macOS Keychain credential — affects running claude sessions.")
    }

    private func disabledVerb(_ title: String) -> some View {
        HStack { Spacer(); Text(title).font(Theme.sub); Spacer() }
            .frame(height: 34).foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

}
