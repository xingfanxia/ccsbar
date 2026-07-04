import AppKit

/// Owns the menu-bar `NSStatusItem` and its `NSMenu`. The menu is rebuilt from
/// `status.json` each time it opens (`menuNeedsUpdate`); a light timer refreshes
/// the title so the active account + 5h meter stay current without the menu open.
///
/// Layout: a title showing the active account name + 5h%, then per-account rows
/// (5h / 7d / fable bars + fallback status), a fallback-chain summary, and a
/// `Configure ▸` submenu that drives the daemon's config socket (add/remove/
/// reorder chain members, per-member threshold, wrap-off).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var timer: Timer?

    /// Threshold presets offered in the per-account Threshold submenu.
    private let thresholdPresets = [50, 80, 90, 95, 100]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                accessibilityDescription: "clauth"
            ) ?? NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "clauth")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }

        refreshGlyph()
        timer = Timer.scheduledTimer(
            timeInterval: 5, target: self, selector: #selector(tick),
            userInfo: nil, repeats: true
        )
    }

    @objc private func tick() { refreshGlyph() }

    /// Menu-bar button: active account **name + 5h%** (name makes the active
    /// account unmistakable), the % tinted by utilization, plus a rich tooltip.
    private func refreshGlyph() {
        guard let status = DaemonClient.readStatus() else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.toolTip = "clauth daemon not running"
            return
        }
        guard let active = status.profiles.first(where: { $0.active }) else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.toolTip = "no active account"
            return
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString(
            string: " \(active.name) ",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        // Distinguish "no 5h window yet" (never fetched) from a real 0% — a green
        // "0%" for unknown usage is exactly the wrong signal for a quota app, and
        // it would contradict the dropdown row (which shows "—").
        if let five = active.fiveHour {
            let pct = five.utilizationPct
            title.append(NSAttributedString(
                string: "\(Int(pct.rounded()))%",
                attributes: [.font: font, .foregroundColor: Theme.utilColor(pct)]
            ))
        } else {
            title.append(NSAttributedString(
                string: "—",
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        statusItem.button?.attributedTitle = title

        let fiveStr = active.fiveHour.map { "5h \(Int($0.utilizationPct.rounded()))%" } ?? "5h —"
        let sd = active.sevenDay.map { "  7d \(Int($0.utilizationPct.rounded()))%" } ?? ""
        let fb = active.fableWeek.map { "  fable \(Int($0.utilizationPct.rounded()))%" } ?? ""
        let stale = active.isStale ? "  (\(active.fetchStatus ?? "stale"))" : ""
        statusItem.button?.toolTip = "\(active.name) — \(fiveStr)\(sd)\(fb)\(stale)"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let status = DaemonClient.readStatus() else {
            let item = NSMenuItem(title: "clauth daemon not running", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            addQuit(to: menu)
            return
        }

        // Accounts — active pinned first, then file order.
        let ordered = status.profiles.sorted { a, b in a.active && !b.active }
        for profile in ordered {
            menu.addItem(accountItem(for: profile))
        }

        menu.addItem(.separator())
        menu.addItem(chainSummaryItem(status))
        menu.addItem(configureItem(status))

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshClicked), keyEquivalent: "")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refresh)
        addQuit(to: menu)
    }

    // MARK: - Account rows

    private func accountItem(for p: ProfileStatus) -> NSMenuItem {
        let item = NSMenuItem(title: p.name, action: #selector(switchClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = p.name
        item.attributedTitle = accountTitle(for: p)
        item.state = p.active ? .on : .off
        item.toolTip = p.active ? "Active account" : "Click to switch to \(p.name)"
        return item
    }

    /// Multi-line row: `● name  tier`, then 5h / 7d / fable bars, then a fallback
    /// line and (if not Fresh) a staleness cue.
    private func accountTitle(for p: ProfileStatus) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let dim = NSColor.secondaryLabelColor
        let title = NSMutableAttributedString()

        // Line 1 — dot + bold name + plan tier.
        let dot = p.active ? "● " : "○ "
        title.append(NSAttributedString(
            string: dot,
            attributes: [.foregroundColor: p.active ? Theme.orange : NSColor.tertiaryLabelColor]
        ))
        title.append(NSAttributedString(
            string: p.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: p.active ? Theme.orange : NSColor.labelColor,
            ]
        ))
        // Line-1 secondary label: plan tier (OAuth) or provider (third-party/api-key).
        let isThirdParty = p.provider != "anthropic"
        if let secondary = isThirdParty ? p.provider : p.tier {
            title.append(NSAttributedString(
                string: "   \(secondary)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim]
            ))
        }

        if isThirdParty {
            // Third-party / api-key accounts have no OAuth 5h/7d/fable windows — the
            // daemon only reports up/down. Show availability instead of empty bars.
            let (text, color): (String, NSColor)
            switch p.thirdParty?.available {
            case .some(true): (text, color) = ("● available", Theme.success)
            case .some(false): (text, color) = ("○ unavailable", Theme.danger)
            case .none: (text, color) = ("— no data yet", NSColor.tertiaryLabelColor)
            }
            title.append(NSAttributedString(
                string: "\n\(text)", attributes: [.font: mono, .foregroundColor: color]
            ))
        } else {
            // OAuth usage windows — 5h colored by its fallback threshold when a member.
            title.append(windowLine("5h", p.fiveHour, threshold: p.fallback?.threshold, mono: mono))
            title.append(windowLine("7d", p.sevenDay, threshold: nil, mono: mono))
            title.append(windowLine("fable", p.fableWeek, threshold: nil, mono: mono))
        }

        // Fallback status.
        if let fb = p.fallback {
            let armed = fb.armed ? "  ✓ armed" : ""
            title.append(NSAttributedString(
                string: "\n⚡ chain #\(fb.position) · \(Int(fb.threshold))%\(armed)",
                attributes: [.font: mono, .foregroundColor: fb.armed ? Theme.sapphire : dim]
            ))
        } else {
            title.append(NSAttributedString(
                string: "\n· not in fallback chain",
                attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }

        if p.isStale {
            title.append(NSAttributedString(
                string: "   (\(p.fetchStatus ?? "stale"))",
                attributes: [.font: mono, .foregroundColor: Theme.warning]
            ))
        }
        return title
    }

    /// `label ████░░░░ 42%  resets 3h` — one window's bar, %, and reset hint.
    private func windowLine(
        _ label: String, _ w: UsageWindow?, threshold: Double?, mono: NSFont
    ) -> NSAttributedString {
        let dim = NSColor.secondaryLabelColor
        let out = NSMutableAttributedString()
        let pad = label.padding(toLength: 5, withPad: " ", startingAt: 0)
        out.append(NSAttributedString(
            string: "\n\(pad) ", attributes: [.font: mono, .foregroundColor: dim]
        ))
        guard let w else {
            out.append(NSAttributedString(
                string: "—", attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
            return out
        }
        let pct = w.utilizationPct
        let color = threshold.map { Theme.healthColor(pct, threshold: $0) } ?? Theme.utilColor(pct)
        let bar = NSMutableAttributedString(attributedString: Theme.bar(pct: pct, cells: 10, color: color))
        bar.addAttribute(.font, value: mono, range: NSRange(location: 0, length: bar.length))
        out.append(bar)
        out.append(NSAttributedString(
            string: String(format: "  %3.0f%%", pct),
            attributes: [.font: mono, .foregroundColor: dim]
        ))
        if let hint = Theme.resetHint(w.resetsAt) {
            out.append(NSAttributedString(
                string: "  \(hint)",
                attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        return out
    }

    // MARK: - Fallback chain summary + configuration

    /// Disabled info row: the chain in order + wrap-off state.
    private func chainSummaryItem(_ status: DaemonStatus) -> NSMenuItem {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = NSMutableAttributedString(
            string: "Fallback chain\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        let chain = status.fallbackChain.isEmpty ? "—" : status.fallbackChain.joined(separator: " → ")
        text.append(NSAttributedString(
            string: chain,
            attributes: [.font: mono, .foregroundColor: NSColor.labelColor]
        ))
        text.append(NSAttributedString(
            string: "\nwrap-off: \(status.wrapOff ? "on — switch all off when spent" : "off — stay on last")",
            attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]
        ))
        let item = NSMenuItem()
        item.attributedTitle = text
        item.isEnabled = false
        return item
    }

    /// `Configure ▸` — per-account config submenus + a wrap-off toggle.
    private func configureItem(_ status: DaemonStatus) -> NSMenuItem {
        let root = NSMenuItem(title: "Configure", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let sub = NSMenu()

        for p in status.profiles {
            let accItem = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
            let mark = p.inChain ? "⚡ " : ""
            accItem.attributedTitle = NSAttributedString(string: "\(mark)\(p.name)")
            accItem.submenu = accountConfigMenu(for: p, status: status)
            sub.addItem(accItem)
        }

        sub.addItem(.separator())
        let wrap = NSMenuItem(
            title: "Wrap-off mode", action: #selector(wrapOffClicked(_:)), keyEquivalent: ""
        )
        wrap.target = self
        wrap.state = status.wrapOff ? .on : .off
        wrap.representedObject = !status.wrapOff // clicking flips it
        wrap.toolTip = "When the whole chain is spent: on = switch every account off; off = stay on the last."
        sub.addItem(wrap)

        root.submenu = sub
        return root
    }

    /// One account's config actions: add, or (in-chain) threshold / reorder / remove.
    private func accountConfigMenu(for p: ProfileStatus, status: DaemonStatus) -> NSMenu {
        let menu = NSMenu()
        // Honor our explicit `isEnabled` (Move up/down grey out at the ends);
        // otherwise NSMenu auto-enables anything with a target+action.
        menu.autoenablesItems = false
        guard let fb = p.fallback else {
            let add = NSMenuItem(title: "Add to fallback chain", action: #selector(addClicked(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = p.name
            menu.addItem(add)
            return menu
        }

        // Threshold submenu with the current value checked.
        let thr = NSMenuItem(title: "Threshold (\(Int(fb.threshold))%)", action: nil, keyEquivalent: "")
        let thrMenu = NSMenu()
        for v in thresholdPresets {
            let opt = NSMenuItem(title: "\(v)%", action: #selector(thresholdClicked(_:)), keyEquivalent: "")
            opt.target = self
            opt.representedObject = ["name": p.name, "value": v]
            opt.state = Int(fb.threshold) == v ? .on : .off
            thrMenu.addItem(opt)
        }
        thr.submenu = thrMenu
        menu.addItem(thr)

        // Reorder — disabled at the ends.
        let up = NSMenuItem(title: "Move up", action: #selector(moveClicked(_:)), keyEquivalent: "")
        up.target = self
        up.representedObject = ["name": p.name, "up": true]
        up.isEnabled = fb.position > 1
        menu.addItem(up)

        let down = NSMenuItem(title: "Move down", action: #selector(moveClicked(_:)), keyEquivalent: "")
        down.target = self
        down.representedObject = ["name": p.name, "up": false]
        down.isEnabled = fb.position < status.fallbackChain.count
        menu.addItem(down)

        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from chain", action: #selector(removeClicked(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = p.name
        menu.addItem(remove)
        return menu
    }

    private func addQuit(to menu: NSMenu) {
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit clauthbar", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func switchClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DaemonClient.switchTo(name)
        pokeRefresh()
    }

    @objc private func refreshClicked() { DaemonClient.refresh(nil) }

    @objc private func addClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DaemonClient.fallbackAdd(name)
        pokeRefresh()
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DaemonClient.fallbackRemove(name)
        pokeRefresh()
    }

    @objc private func moveClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let name = info["name"] as? String,
              let up = info["up"] as? Bool else { return }
        DaemonClient.fallbackMove(name, up: up)
        pokeRefresh()
    }

    @objc private func thresholdClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let name = info["name"] as? String,
              let value = info["value"] as? Int else { return }
        DaemonClient.setThreshold(name, value)
        pokeRefresh()
    }

    @objc private func wrapOffClicked(_ sender: NSMenuItem) {
        guard let on = sender.representedObject as? Bool else { return }
        DaemonClient.setWrapOff(on)
        pokeRefresh()
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }

    /// Config/switch edits land on the daemon's next tick (~1s); refresh the
    /// title a beat later so the menu-bar meter reflects it. The dropdown itself
    /// rebuilds from status.json the next time it opens.
    private func pokeRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshGlyph()
        }
    }
}
