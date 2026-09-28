import SwiftUI

/// Under the codex active line: codex's shared app-server daemon still holds
/// the login it read at start (clauth `codex_app_server_stale`). Every task
/// runs inside that daemon and `codex resume` reconnects to it, so a switch
/// reaches no task until it restarts (2026-09-27: a resumed task kept spending
/// a week-spent account). Sits beside the line it qualifies rather than in a
/// panel-top banner, and the button says what it costs.
struct CodexServerNotice: View {
    @ObservedObject var model: StatusModel
    let stale: CodexAppServerStale
    let activeName: String
    @State private var requested = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.message(activeName: activeName, startedAt: stale.startedAt))
                    .font(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Button(requested ? "Restarting…" : "Restart Codex server") {
                    requested = true
                    model.restartCodexDaemon()
                }
                .controlSize(.small)
                .tint(Theme.codex)
                .disabled(requested)
                .help("Runs `codex app-server daemon restart`. Tasks mid-turn stop that turn; resume them afterwards.")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
    }

    /// The notice copy: what is still happening and to which account, in the
    /// user's terms. Pure so it is unit-tested.
    static func message(activeName: String, startedAt: String, now: Date = Date()) -> String {
        var since = ""
        if let started = Theme.parseISO(startedAt) {
            since = " (started \(StatusModel.ago(Int(now.timeIntervalSince(started)))))"
        }
        return "Codex tasks still run on the login the Codex server started with\(since), "
            + "not \(activeName). Restart it to move them over; tasks mid-turn stop that turn."
    }
}
