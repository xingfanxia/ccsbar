import SwiftUI

/// Process entry (the executable target's `@main` calls this). Normally runs the
/// menu-bar app; `--snapshot <path>` renders the panel to a PNG and exits (a dev
/// aid, see `Snapshot`). Public so the thin `ccsbar` executable can invoke it;
/// everything else in CCSBarKit stays internal for `@testable import`.
@MainActor
public func runCCSBar() {
    let args = CommandLine.arguments
    // `--snapshot <path>` renders the healthy panel to a PNG.
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        Snapshot.render(to: args[i + 1])
        return
    }
    // `--snapshot=<variant>[:<light|dark>][@<scale>]` renders a liveness variant to a
    // temp PNG and prints the resolved state (TECH-4 verification harness). The
    // optional `:light`/`:dark` picks the appearance (default dark); `@<scale>`
    // renders at a higher scale for crisp media (default 2 → 340pt/680px).
    // e.g. `--snapshot=healthy:light`, `--snapshot=spent:dark@3`.
    if let arg = args.first(where: { $0.hasPrefix("--snapshot=") }) {
        var raw = String(arg.dropFirst("--snapshot=".count))
        var scale: CGFloat = 2
        if let at = raw.firstIndex(of: "@") {
            scale = Double(raw[raw.index(after: at)...]).map { CGFloat($0) } ?? 2
            raw = String(raw[..<at])
        }
        var appearance = Snapshot.Appearance.dark
        if let colon = raw.firstIndex(of: ":") {
            appearance = Snapshot.Appearance(rawValue: String(raw[raw.index(after: colon)...])) ?? .dark
            raw = String(raw[..<colon])
        }
        let variant = raw
        let scaleSuffix = scale == 2 ? "" : "@\(Int(scale))x"
        let path = NSTemporaryDirectory() + "ccsbar-snapshot-\(variant)-\(appearance.rawValue)\(scaleSuffix).png"
        Snapshot.render(variant: variant, to: path, scale: scale, appearance: appearance)
        return
    }
    // Real app path only (the --snapshot render above is expected to run alongside
    // a live app, so it must NOT trip the guard): refuse to be a second instance,
    // then register for autostart so the panel survives a reboot (TECH-14 #33/#42).
    guard SingleInstance.acquire() else {
        return // another ccsbar already owns the slot — bow out
    }
    LoginItem.registerIfNeeded()
    CCSBarApp.main()
}

/// A menu-bar-only SwiftUI app (`LSUIElement` in Info.plist keeps it out of the
/// Dock). `MenuBarExtra(.window)` gives a translucent SwiftUI panel — the same
/// style CodexBar uses — instead of a plain `NSMenu`.
struct CCSBarApp: App {
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

/// The menu-bar item, driven by the pure `MenuBarLabelLadder` (CBAR4-6, design §6):
/// a state glyph + active account name + 5h % (or a frozen age / "off" / availability
/// dot). ALL state is in SF Symbol SHAPE — the menu bar template-renders, so color is
/// never load-bearing here.
private struct MenuBarLabel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        let spec = MenuBarLabelLadder.spec(
            status: model.status,
            switchInFlight: model.switchInFlight,
            rotationFlash: model.rotationFlash,
            now: Date()
        )
        HStack(spacing: 3) {
            Image(systemName: spec.symbol)
            if spec.nearThresholdDot {
                Image(systemName: "circlebadge.fill").font(.system(size: 5))
            }
            if !spec.text.isEmpty {
                Text(spec.text).font(.system(size: 13)).monospacedDigit().lineLimit(1)
            }
            if let available = spec.availabilityDot {
                Image(systemName: available ? "circle.fill" : "circle").font(.system(size: 6))
            }
            if let trailing = spec.trailingSymbol {
                Image(systemName: trailing)
            }
        }
    }
}
