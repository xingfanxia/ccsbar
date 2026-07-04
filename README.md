# clauthbar

A native macOS menu-bar companion for [clauth](https://github.com/xingfanxia/clauth)
— glance at every Claude Code account's 5-hour usage and switch with one click,
without opening the TUI.

clauthbar is a thin UI over clauth's daemon: it reads `~/.clauth/status.json`
(written every tick by `clauth daemon`) for display and drives
`~/.clauth/clauthd.sock` (with a `clauth <name>` shell fallback) to switch. It
owns no credentials and runs no network of its own.

## Requirements

- macOS 14+ (Sonoma), Swift 6 toolchain (Xcode 16+).
- `clauth` installed and the daemon running:
  ```sh
  # from the clauth repo
  dist/macos/daemon-install.sh      # LaunchAgent (runs at login), or:
  clauth daemon                     # foreground, for a quick try
  ```
  Without a running daemon, `status.json` goes stale and the menu shows
  "clauth daemon not running".

## Run (development)

```sh
swift run          # launches as a menu-bar accessory (no Dock icon)
```

The menu-bar title shows the **active account name + 5h %** (so the active
account is unmistakable at a glance). The dropdown lists every account — active
pinned on top with an orange dot — each with its plan tier, **5h / 7d / fable
usage bars** (with % and a "resets in" hint), and its fallback status
(`⚡ chain #position · threshold%` + armed). Below that: a **Fallback chain**
summary (order + wrap-off state) and a **Configure ▸** submenu to edit the chain
without leaving the bar — per-account threshold picker, move up/down, add/remove,
and a wrap-off toggle. Click an account to switch; "Refresh now" forces a
re-fetch; "Quit" exits.

Configuration drives the daemon's control socket (`clauthd.sock`), so a running
`clauth daemon` is required to edit (display works off `status.json` alone).

## Build a real app

```sh
Scripts/package_app.sh        # → build/clauthbar.app (LSUIElement, ad-hoc signed)
open build/clauthbar.app      # run it, or:
cp -R build/clauthbar.app /Applications/   # then add to System Settings → Login Items
```

## Status (MVP)

Implemented:

- `NSStatusItem` + `NSMenu`, rebuilt from `status.json` on open.
- Menu-bar title: active account **name + 5h %** (color-tinted by utilization).
- Per-account rows: active dot, tier badge, **5h / 7d / fable bars + % + reset
  hint**, fallback line (`⚡ chain #pos · threshold%` + armed), staleness cue —
  colored from clauth's TUI palette (Catppuccin Mocha).
- **Fallback chain summary** (order + wrap-off state).
- **Configure ▸** submenu — per-account threshold picker, move up/down, add/remove,
  and a wrap-off toggle, driving the daemon's config socket commands.
- One-click switch (socket, `clauth <name>` fallback) + Refresh + Quit.
- Runs as an accessory app (no Dock icon); packaged as an ad-hoc-signed `.app`.

Deferred:

- **S4** — the polished hosted-SwiftUI card (real `Canvas` usage bars via
  `NSHostingView` + `intrinsicContentSize`). The rows draw bars with block
  characters in native menu items instead.
- **S7 (partial)** — `.app` bundling done (`Scripts/package_app.sh`, ad-hoc
  signed). Still deferred: dedicated Settings window, Sparkle auto-update,
  Developer-ID signing + notarization, Homebrew cask.
- `Add Account…` (→ `clauth login`), custom meter glyph.

## Architecture

| File | Role |
|---|---|
| `DaemonStatus.swift` | `Codable` mirror of `status.json` (schema 1) |
| `DaemonClient.swift` | read `status.json`; `switch`/`refresh` over the socket (shell fallback) |
| `Theme.swift` | palette + `util_color`/`health_color` + text usage bar |
| `StatusItemController.swift` | the `NSStatusItem` + `NSMenu` (delegate rebuild + actions) |
| `AppMain.swift` | `@main` accessory app shell |

The full design (why `NSMenu` over `MenuBarExtra`, the `intrinsicContentSize`
trick, the visual spec, and the daemon IPC contract) lives in the clauth repo at
`docs/clauthbar/DESIGN.md`.
