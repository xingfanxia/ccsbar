import SwiftUI

/// Polls `~/.clauth/status.json` on a timer and publishes it to the panel + the
/// menu-bar label. Also the one place that fires switch/config commands at the
/// daemon (via `DaemonClient`) and schedules a quick re-read so the UI reflects
/// the change once the daemon's next tick lands it (~1s).
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var status: DaemonStatus?
    @Published var showConfig = false

    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Preview/snapshot init: inject a fixed status, no polling.
    init(preview: DaemonStatus) {
        self.status = preview
    }

    func reload() { status = DaemonClient.readStatus() }

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
