import SwiftUI

/// Polls `~/.clauth/status.json` on a timer and publishes it to the panel + the
/// menu-bar label. Also the one place that fires switch/config commands at the
/// daemon (via `DaemonClient`) and schedules a quick re-read so the UI reflects
/// the change once the daemon's next tick lands it (~1s).
@MainActor
final class StatusModel: ObservableObject {
    /// Daemon liveness the panel must render distinctly (TECH-4). `.ok` shows the
    /// live panel; `.stalled` overlays a banner on the (last-known) content;
    /// `.outOfDate` and `.down` are separate empty states — never a fresh-looking
    /// panel over a dead daemon.
    enum Liveness: Equatable, Sendable {
        case ok
        case stalled(since: String)
        case outOfDate(schema: Int)
        case down
    }

    @Published private(set) var status: DaemonStatus?
    @Published private(set) var liveness: Liveness = .down
    @Published var showConfig = false

    private var timer: Timer?

    private var lastMtime: Date?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Let the OS coalesce the 4s poll for power (TECH-14 #31) — a rebuildable
        // status read has no need to be punctual to the millisecond.
        timer?.tolerance = 1.0
    }

    /// Preview/snapshot init: inject a fixed status + liveness, no polling.
    init(preview: DaemonStatus?, liveness: Liveness = .ok) {
        self.status = preview
        self.liveness = liveness
    }

    /// The active account is only trustworthy when live — the menu-bar glyph dims
    /// otherwise so a frozen % never reads as current.
    var isHealthy: Bool { liveness == .ok }

    func reload() {
        // Republish gate (TECH-14 #31): when status.json hasn't changed, skip the
        // re-decode and don't churn @Published — but STILL recompute liveness,
        // because a file that stopped advancing is exactly the stalled case (its
        // age grows with wall-clock even though the bytes don't).
        let mtime = DaemonClient.statusMtime()
        if let mtime, mtime == lastMtime, let s = status {
            let next = Self.staleness(of: s)
            if next != liveness { liveness = next }
            return
        }
        lastMtime = mtime

        switch DaemonClient.readStatus() {
        case .ok(let s):
            status = s
            liveness = Self.staleness(of: s)
        case .schemaUnsupported(let n):
            // Distinct from "down": the daemon IS writing, we just can't read its
            // format. Drop the (unparsed) content and show the out-of-date state.
            status = nil
            liveness = .outOfDate(schema: n)
        case .fileMissing, .decodeFailed:
            status = nil
            liveness = .down
        }
    }

    /// A daemon that dies AFTER writing status.json freezes the file `Fresh`; the
    /// only truth is `generated_at` age. Stale once older than 3× the refresh
    /// interval (floored at 15s) — the daemon rewrites every 1s tick, so that gap
    /// means it stopped ticking.
    private static func staleness(of s: DaemonStatus) -> Liveness {
        guard let written = Theme.parseISO(s.generatedAt) else { return .ok }
        let age = Date().timeIntervalSince(written)
        let staleAfter = max(3 * Double(s.refreshIntervalMs) / 1000, 15)
        guard age > staleAfter else { return .ok }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return .stalled(since: f.string(from: written))
    }

    var active: ProfileStatus? { status?.profiles.first { $0.active } }

    /// Active pinned first, then file order — the switcher's tile order.
    var orderedProfiles: [ProfileStatus] {
        (status?.profiles ?? []).sorted { a, b in a.active && !b.active }
    }

    // MARK: - Commands (fire, then re-read once the daemon lands it)

    func switchTo(_ name: String) { dispatch { DaemonClient.switchTo(name) } }
    func fallbackAdd(_ name: String) { dispatch { DaemonClient.fallbackAdd(name) } }
    func fallbackRemove(_ name: String) { dispatch { DaemonClient.fallbackRemove(name) } }
    func fallbackMove(_ name: String, up: Bool) { dispatch { DaemonClient.fallbackMove(name, up: up) } }
    func setThreshold(_ name: String, _ value: Int) { dispatch { DaemonClient.setThreshold(name, value) } }
    func setWrapOff(_ on: Bool) { dispatch { DaemonClient.setWrapOff(on) } }
    func refresh() { dispatch { DaemonClient.refresh(nil) } }

    /// Run a daemon command's blocking socket I/O OFF the main actor (TECH-10 #25 —
    /// a switch can park the socket for ~2s while the daemon holds its config lock
    /// across a Keychain rewrite; doing that on @MainActor is the beach-ball), then
    /// hop back to settle the UI. The command closures are fire-and-forget, so the
    /// call sites stay synchronous.
    private func dispatch(_ work: @escaping @Sendable () -> Void) {
        Task { [weak self] in
            await Task.detached(operation: work).value
            self?.settle()
        }
    }

    /// The daemon applies queued edits on its next ~1s tick; re-read shortly after
    /// so the panel updates without waiting for the 4s poll.
    private func settle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.reload() }
    }
}
