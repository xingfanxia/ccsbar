import AppKit
import SwiftUI

/// Headless render of `PanelView` (with mock data) to a PNG — a dev aid so the
/// panel's look can be reviewed without opening the menu bar. Invoked via
/// `clauthbar --snapshot <path>`; never part of the normal app run.
enum Snapshot {
    /// A realistic status.json exercising every panel path: an active OAuth
    /// account with 5h/7d/fable usage (accent + warning fills), a second chain
    /// member, and a third-party (api-key) account with an availability flag.
    static let mockJSON = """
    {
      "schema": 1,
      "generated_at": "2026-07-04T05:00:00+00:00",
      "active_profile": "xfx",
      "wrap_off": false,
      "refresh_interval_ms": 90000,
      "fallback_chain": ["xfx", "cl-ax"],
      "profiles": [
        {
          "name": "xfx", "active": true, "provider": "anthropic", "base_url": null,
          "tier": "Max 20x", "has_live_session": false, "fetch_status": "Fresh",
          "fetched_at": "2026-07-04T04:59:00+00:00", "next_refresh_at": null,
          "auto_start": false, "bell_threshold": null,
          "fallback": {"position": 1, "threshold": 95, "armed": true},
          "windows": [
            {"label": "5h", "utilization_pct": 42, "resets_at": "2026-07-04T20:00:00.519183+00:00"},
            {"label": "7d", "utilization_pct": 78, "resets_at": "2026-07-10T00:00:00.519205+00:00"},
            {"label": "7d fable", "utilization_pct": 12, "resets_at": "2026-07-10T00:00:00.519205+00:00"}
          ],
          "third_party": null
        },
        {
          "name": "cl-ax", "active": false, "provider": "anthropic", "base_url": null,
          "tier": "Max 20x", "has_live_session": false, "fetch_status": "Fresh",
          "fetched_at": null, "next_refresh_at": null, "auto_start": false, "bell_threshold": null,
          "fallback": {"position": 2, "threshold": 95, "armed": false},
          "windows": [
            {"label": "5h", "utilization_pct": 8, "resets_at": "2026-07-04T18:00:00.100000+00:00"},
            {"label": "7d", "utilization_pct": 31, "resets_at": null},
            {"label": "7d fable", "utilization_pct": 0, "resets_at": null}
          ],
          "third_party": null
        },
        {
          "name": "zai", "active": false, "provider": "z.ai",
          "base_url": "https://api.z.ai", "tier": null, "has_live_session": false,
          "fetch_status": "Fresh", "fetched_at": null, "next_refresh_at": null,
          "auto_start": false, "bell_threshold": null, "fallback": null,
          "windows": [], "third_party": {"available": true}
        }
      ]
    }
    """

    /// Back-compat: `--snapshot <path>` renders the healthy panel.
    @MainActor
    static func render(to path: String) { render(variant: "healthy", to: path) }

    /// Render a specific liveness variant (TECH-4 harness): `healthy` (live panel),
    /// `stale` (stalled banner over content), `schema2` (clauthbar-out-of-date
    /// state). Prints the RESOLVED liveness to stderr so the state logic is
    /// verifiable without eyeballing the PNG (`--snapshot=stale` → daemonStalled=true).
    @MainActor
    static func render(variant: String, to path: String) {
        guard let mock = try? JSONDecoder().decode(DaemonStatus.self, from: Data(mockJSON.utf8)) else {
            FileHandle.standardError.write(Data("snapshot: failed to decode mock\n".utf8))
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
