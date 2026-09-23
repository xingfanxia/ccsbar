import SwiftUI

/// The codex use-a-reset half of `StatusModel`: a codex account's banked
/// usage-limit reset, spent from the row's context menu through an armed
/// confirm and `clauth use-reset <name> --yes`. Stored properties stay in the
/// class declaration; this file is same-type extensions only.
extension StatusModel {
    // MARK: - Visibility + gating (pure)

    /// Whether a row's context menu offers "Use a usage-limit reset…": a codex
    /// row whose daemon-carried count is above zero. Keyed on the SAME
    /// predicate as the row's reset chip (`CodexStrip.bankedCount`), so the
    /// menu never offers a reset the row doesn't show, or the reverse — nil
    /// (older daemon, no poll yet) and 0 both hide it. Main-actor like
    /// `bankedCount` (a `View` static); every caller is a view or the model.
    static func offersUseReset(_ p: ProfileStatus) -> Bool {
        p.isCodex && CodexStrip.bankedCount(p) != nil
    }

    /// The context-menu title. The count rides in it so the choice is informed
    /// before the confirm opens.
    nonisolated static func useResetMenuTitle(_ available: Int) -> String {
        "Use a usage-limit reset… (\(available) left)"
    }

    /// A reset may not start while another reset, a delete, or a login spawn
    /// is in flight: a delete or a login rewrites the very profile whose stored
    /// login `clauth use-reset` reads. One gate for the menu item AND the
    /// banner's button, so neither is an enabled control that silently no-ops.
    var useResetBlocked: Bool {
        resetInFlight != nil || deleteInFlight != nil || loginInFlight != nil
    }

    // MARK: - Armed confirm

    /// Arm the use-reset confirm for `name`. ALWAYS confirms — a used reset
    /// can't be returned — and never spends from the menu directly.
    func requestReset(_ name: String) { pendingReset = name }
    func cancelReset() { pendingReset = nil }

    /// Drop the arm once its target can't be confirmed in the latest status:
    /// gone, renamed away, out of resets, or no status at all. Called wherever
    /// status is republished, so a stale arm is CLEARED rather than merely
    /// hidden — otherwise a new reset granted days later (or a new account
    /// taking the name) would bring the banner back with nobody having armed it.
    func dropStaleResetArm(against published: DaemonStatus?) {
        guard let armed = pendingReset else { return }
        if !(published?.profiles.first(where: { $0.name == armed }).map(Self.offersUseReset) ?? false) {
            pendingReset = nil
        }
    }

    /// The confirm copy for the pending reset, or nil when none is pending —
    /// or when the target vanished (renamed, deleted) or its count dropped to
    /// zero while the banner sat open (spent from the Codex app, or expired).
    /// Same self-healing the delete confirm has: a banner must never outlive
    /// the thing it asks about.
    var pendingResetPrompt: String? {
        guard let name = pendingReset,
              let p = listProfiles.first(where: { $0.name == name }),
              Self.offersUseReset(p), let available = p.codexResetCredits
        else { return nil }
        return Self.useResetPrompt(
            name, available: available,
            fiveHourPct: p.fiveHour?.utilizationPct, weeklyPct: p.sevenDay?.utilizationPct)
    }

    /// The use-reset confirm copy: whose reset, how many are banked, what it
    /// does (reopens both windows NOW — so it is worth the most when they're
    /// nearly spent, hence the current figures), and that it is final. The
    /// figures say "used" in words, so they read the same whichever axis the
    /// panel is counting on. Pure so it's unit-tested without a daemon.
    nonisolated static func useResetPrompt(
        _ name: String, available: Int, fiveHourPct: Double?, weeklyPct: Double?
    ) -> String {
        var prompt = available == 1
            ? "Use the one usage-limit reset on '\(name)'?"
            : "Use one of the \(available) usage-limit resets on '\(name)'?"
        prompt += " It reopens the 5-hour and weekly windows right away."
        let now = [
            fiveHourPct.map { "5h \(Int($0.rounded()))%" },
            weeklyPct.map { "weekly \(Int($0.rounded()))%" },
        ].compactMap { $0 }
        if !now.isEmpty {
            prompt += " Now: \(now.joined(separator: " · ")) used."
        }
        prompt += " A used reset can't be returned."
        return prompt
    }

    // MARK: - Spend

    /// Commit the armed reset: spawn `clauth use-reset <name> --yes`. CLI-only
    /// (no socket verb), so it works with the daemon down. On success the
    /// neutral notice carries clauth's own summary and — when the daemon is
    /// reachable — a forced re-poll of that account, so its bars and count
    /// update now rather than at the next ~90s refetch. A failure is clauth's
    /// own words in the error banner. Never retried: an unconfirmed outcome
    /// retried could spend a second reset. For the same reason a failure
    /// (which may be unconfirmed — the consume may have landed) also forces a
    /// QUIET re-poll, so the menu's count and any re-armed confirm stop showing
    /// the pre-spend figure without the re-poll clearing the error banner.
    /// `runReset` and `repoll(name, quiet)` are injected so outcome routing is
    /// testable without spawning or touching the socket.
    func confirmReset(
        runReset: (@Sendable (String) async -> DaemonClient.UseResetOutcome)? = nil,
        repoll: (@MainActor (String, _ quiet: Bool) -> Void)? = nil
    ) {
        guard let name = pendingReset else { return }
        // Blocked: the armed state survives, so the user can confirm once the
        // in-flight spawn settles (the banner's button shows the same gate).
        guard !useResetBlocked else { return }
        // The target may have vanished, or run out of resets, while the banner
        // sat open — firing at it is a guaranteed refusal, so drop the arm.
        guard let p = listProfiles.first(where: { $0.name == name }), Self.offersUseReset(p) else {
            pendingReset = nil
            return
        }
        pendingReset = nil
        let runner = runReset ?? { await DaemonClient.useReset($0) }
        // Same daemon-down policy as the login flows: the reset outcome stands;
        // a socket refresh would only raise a false "daemon unreachable" — the
        // next daemon tick picks it up.
        let repoll = repoll ?? { [weak self] name, quiet in
            guard let self, self.daemonReachable else { return }
            if quiet { self.refreshQuietly(name) } else { self.refresh(name) }
        }
        resetInFlight = name
        lastCommandError = nil
        errorClearTask?.cancel()
        Task { [weak self] in
            let outcome = await runner(name)
            guard let self else { return }
            self.resetInFlight = nil
            switch outcome {
            case .used(let summary):
                self.showNotice(summary ?? "Used a usage-limit reset on '\(name)'.")
                repoll(name, false)
            case .failed(let message):
                self.showError(message)
                repoll(name, true)
            case .unreachable:
                self.showError("Couldn't find the clauth binary. Run `clauth use-reset \(name)` in a terminal.")
            }
        }
    }
}
