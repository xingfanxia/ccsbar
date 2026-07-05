import SwiftUI

/// Process entry (the executable target's `@main` calls this). Normally runs the
/// menu-bar app; `--snapshot <path>` renders the panel to a PNG and exits (a dev
/// aid, see `Snapshot`). Public so the thin `clauthbar` executable can invoke it;
/// everything else in ClauthBarKit stays internal for `@testable import`.
@MainActor
public func runClauthBar() {
    let args = CommandLine.arguments
    // `--snapshot <path>` renders the healthy panel to a PNG.
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        Snapshot.render(to: args[i + 1])
        return
    }
    // `--snapshot=<variant>` renders a liveness variant (healthy|stale|schema2)
    // to a temp PNG and prints the resolved state (TECH-4 verification harness).
    if let arg = args.first(where: { $0.hasPrefix("--snapshot=") }) {
        let variant = String(arg.dropFirst("--snapshot=".count))
        let path = NSTemporaryDirectory() + "clauthbar-snapshot-\(variant).png"
        Snapshot.render(variant: variant, to: path)
        return
    }
    ClauthBarApp.main()
}

/// A menu-bar-only SwiftUI app (`LSUIElement` in Info.plist keeps it out of the
/// Dock). `MenuBarExtra(.window)` gives a translucent SwiftUI panel — the same
/// style CodexBar uses — instead of a plain `NSMenu`.
struct ClauthBarApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar item: a gauge glyph + the active account name + its 5h %, so the
/// active account is legible at a glance. Shows "—" (not a misleading 0%) when the
/// active account has no 5h data yet.
private struct MenuBarLabel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(spacing: 3) {
            // Dim the glyph when the daemon isn't live (stalled / out-of-date /
            // down) so a frozen % is never read as current truth (TECH-4).
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .foregroundStyle(model.isHealthy ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            if let active = model.active {
                Text(active.name)
                if let five = active.fiveHour {
                    Text("\(Int(five.utilizationPct.rounded()))%").monospacedDigit()
                } else {
                    Text("—")
                }
            }
        }
    }
}
