import AppKit
import OSLog
import SwiftUI

/// Keeps the menu-bar panel exactly as tall as its content and hanging from the
/// menu bar. `MenuBarExtra(.window)` grows its window for a taller page but never
/// shrinks it back: switching from the Codex page to the shorter Claude page (or
/// collapsing the tokens table) left the window at the old height with the
/// content sitting at its bottom, so a transparent band opened under the menu
/// bar. Measured on the live panel (2026-09-23): the window's top stayed at the
/// menu bar and its height stayed 869pt on every page.
///
/// So the SwiftUI side reports the content's height, and this view sets the
/// window's frame to that height with its top just under the menu bar, on every
/// content change, on open, and after any resize or move the system makes.
struct PanelTopAnchor: NSViewRepresentable {
    /// The panel content's own height (the root view, padding included).
    let contentHeight: CGFloat

    /// The panel's distance below the menu bar.
    static let gap: CGFloat = 1

    /// The frame that is `height` tall, keeps `frame`'s x and width, and hangs
    /// `gap` below `menuBarBottom`. Pure, so the arithmetic is tested.
    static func fittedFrame(_ frame: NSRect, height: CGFloat, menuBarBottom: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: menuBarBottom - gap - height, width: frame.width, height: height)
    }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.contentHeight = contentHeight
        nsView.fit("content")
    }

    final class AnchorView: NSView {
        private static let log = Logger(subsystem: "com.xingfanxia.ccsbar", category: "panel-anchor")
        var contentHeight: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (panel torn down) drops the observers here;
            // they hold `self` weakly, so nothing else needs a deinit.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
                         NSWindow.didMoveNotification] {
                let why = name.rawValue
                observers.append(center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.fit(why)
                        // Once more after the system's own placement pass.
                        DispatchQueue.main.async { self?.fit(why + "+1") }
                    }
                })
            }
            fit("attach")
        }

        /// The bottom edge of the menu bar on the panel's screen: a status-bar
        /// window sitting in that screen's top strip, else the visible frame's
        /// top. (The first cut took ANY status-bar window and once read one
        /// parked off-screen, moving the panel off the top.)
        private func menuBarBottom(for window: NSWindow) -> CGFloat? {
            guard let screen = window.screen ?? NSScreen.main else { return nil }
            let strip = screen.frame.maxY - 80
            let bar = NSApp.windows.first {
                $0 !== window && NSStringFromClass(type(of: $0)).contains("StatusBar")
                    && $0.frame.minY >= strip && $0.frame.maxY <= screen.frame.maxY + 1
            }
            return bar?.frame.minY ?? screen.visibleFrame.maxY
        }

        func fit(_ why: String) {
            guard let window, contentHeight > 1, let bottom = menuBarBottom(for: window) else { return }
            let frame = window.frame
            // The window can be a little taller than its content view (a title
            // strip on some styles); keep that difference.
            let chrome = frame.height - (window.contentView?.frame.height ?? frame.height)
            let target = PanelTopAnchor.fittedFrame(
                frame, height: contentHeight + chrome, menuBarBottom: bottom)
            guard abs(frame.minY - target.minY) > 0.5 || abs(frame.height - target.height) > 0.5
            else { return }
            Self.log.notice(
                "fit \(why, privacy: .public): top \(frame.maxY, privacy: .public) h \(frame.height, privacy: .public) -> top \(target.maxY, privacy: .public) h \(target.height, privacy: .public)")
            window.setFrame(target, display: true)
        }
    }
}
