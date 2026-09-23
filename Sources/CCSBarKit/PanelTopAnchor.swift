import AppKit
import SwiftUI

/// Keeps the menu-bar panel hanging from the menu bar while its content changes
/// height. `MenuBarExtra(.window)` resizes its window around a fixed BOTTOM edge
/// (AppKit's origin is bottom-left), so a page that gets shorter — switching to
/// the Claude tab, collapsing the tokens table — dropped the top edge and left a
/// gap under the menu bar, and a taller one pushed it up under the bar. On every
/// resize this re-pins the top edge where the window first opened.
struct PanelTopAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AnchorView: NSView {
        private var top: CGFloat?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (panel torn down) drops the observers here;
            // they hold `self` weakly, so nothing else needs a deinit.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            top = nil
            guard let window else { return }
            let center = NotificationCenter.default
            // A fresh open re-reads the top: the status item can move between
            // opens (another item added, a different display).
            observers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.top = self?.window?.frame.maxY })
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.repin() })
            top = window.frame.maxY
        }

        private func repin() {
            guard let window, let top else { return }
            let frame = window.frame
            guard abs(frame.maxY - top) > 0.5 else { return }
            window.setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
        }
    }
}
