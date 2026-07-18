import SwiftUI

/// The codex page's "Proxy mode" switch (PROXY-1): one row under the strip,
/// mirroring the panel's "Start at login" Toggle idiom. State is re-read from
/// disk on every panel open — an outside edit of config.toml (operator or
/// zylos's trust-entry maintenance) shows as the switch's real position.
struct CodexProxyRow: View {
    @State private var routed = false
    @State private var serving = false
    @State private var error: String?
    /// Hover expands the explainer in place (the TokensStrip idiom) —
    /// `.help()` tooltips don't reliably surface inside a MenuBarExtra panel.
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { routed }, set: { setRouting($0) })) {
                HStack(spacing: 8) {
                    Image(systemName: "network").frame(width: 16)
                    Text("Proxy mode").font(.body)
                    Spacer()
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(captionStyle)
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            if let error {
                Text(error).font(.caption2).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hovering {
                Text(explainer)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear(perform: refresh)
    }

    private var explainer: String {
        routed
            ? "New codex sessions route through clauth's proxy (:4517): the account "
                + "is injected per request, so clauth switches apply to running "
                + "sessions instantly (in-session hot-swap) and a rate-limited "
                + "request rotates to the next account and replays. Running "
                + "sessions keep the provider they launched with — restart codex "
                + "to adopt."
            : "Codex talks to OpenAI directly; account switches need a codex "
                + "restart. Turn on for in-session hot-swap + rate-limit "
                + "rotate-and-replay via clauth's local proxy (:4517). Applies to "
                + "newly started sessions."
    }

    private var caption: String {
        if routed { return serving ? "serving :4517" : "proxy not running" }
        return serving ? "direct · proxy idle" : "direct"
    }

    private var captionStyle: Color {
        if routed && !serving { return Theme.warning }
        return .secondary
    }

    private func refresh() {
        routed = CodexProxyMode.routed()
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let up = CodexProxyMode.serving()
            DispatchQueue.main.async { serving = up }
        }
    }

    private func setRouting(_ on: Bool) {
        do {
            try CodexProxyMode.apply(on: on)
            routed = on
            error = nil
        } catch {
            self.error = "config.toml edit failed: \(error.localizedDescription)"
        }
        // Re-probe: ON may have just bootstrapped the LaunchAgent.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
            let up = CodexProxyMode.serving()
            DispatchQueue.main.async { serving = up }
        }
    }
}
