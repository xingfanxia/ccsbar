import AppKit
import SwiftUI

/// Headless render of `PanelView` (with mock data) to a PNG — a dev aid so the
/// panel's look can be reviewed without opening the menu bar. Invoked via
/// `clauthbar --snapshot <path>`; never part of the normal app run.
enum Snapshot {
    /// Back-compat: `--snapshot <path>` renders the healthy panel.
    @MainActor
    static func render(to path: String) { render(variant: "healthy", to: path) }

    /// Render a specific liveness variant (TECH-4 harness): `healthy` (live panel),
    /// `stale` (stalled banner over content), `schema2` (clauthbar-out-of-date
    /// state). Prints the RESOLVED liveness to stderr so the state logic is
    /// verifiable without eyeballing the PNG (`--snapshot=stale` → daemonStalled=true).
    @MainActor
    static func render(variant: String, to path: String) {
        guard let data = Fixtures.statusJSONData(),
              let mock = try? JSONDecoder().decode(DaemonStatus.self, from: data)
        else {
            FileHandle.standardError.write(Data("snapshot: failed to load/decode fixture\n".utf8))
            return
        }
        let (status, liveness): (DaemonStatus?, StatusModel.Liveness) = {
            switch variant {
            case "stale": return (mock, .stalled(since: "05:00"))
            case "schema2": return (nil, .outOfDate(schema: 2))
            default: return (mock, .ok)
            }
        }()
        let resolved: String
        switch liveness {
        case .ok: resolved = "ok"
        case .stalled(let s): resolved = "stalled(since: \(s)); daemonStalled=true"
        case .outOfDate(let n): resolved = "outOfDate(schema: \(n))"
        case .down: resolved = "down"
        }
        FileHandle.standardError.write(Data("snapshot[\(variant)]: liveness=\(resolved)\n".utf8))

        let model = StatusModel(preview: status, liveness: liveness)
        model.showConfig = true // render with the config section open
        let view = PanelView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
    }
}
