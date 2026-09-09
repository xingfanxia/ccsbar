import AppKit
import SwiftUI

/// Provider brand glyphs for the tab bar + Overview cards (TABS-1.2) — the
/// actual OpenAI/Anthropic marks instead of stand-in SF Symbols, matching
/// codexbar. The SVGs come from steipete/CodexBar (MIT; see
/// Resources/ICONS-ATTRIBUTION.md) and render as TEMPLATE images so they tint
/// with the surrounding label color (white on the selected pill, secondary
/// when unselected), exactly like codexbar's `ProviderBrandIcon`.
///
/// Loading is dual-path (same pattern as CodexBar's): the packaged .app ships
/// the SVGs in Contents/Resources (package_app.sh copies them — the SPM
/// resource bundle stays dev-only because the FIXTURES in it must not ship),
/// while `swift run`/tests load through `Bundle.module`.
@MainActor
enum ProviderGlyph {
    private static var cache: [Harness: NSImage] = [:]

    /// Drop both caches so a test can exercise the COLD path — the one where
    /// resolving a glyph rasterises it, which is the whole reason the menu-bar
    /// label resolves its marks before it locks focus.
    static func resetCachesForTesting() {
        cache.removeAll()
        inkCache.removeAll()
    }

    private static func resourceName(for harness: Harness) -> String {
        harness == .codex ? "ProviderIcon-codex" : "ProviderIcon-claude"
    }

    /// The harness's brand glyph as a template NSImage, or nil when the
    /// resource is missing (callers fall back to an SF Symbol — a missing
    /// glyph must never blank the tab bar).
    static func image(for harness: Harness) -> NSImage? {
        if let cached = cache[harness] { return cached }
        let name = resourceName(for: harness)
        // Packaged app: Contents/Resources (no SPM bundle ships — fixtures
        // invariant). Dev/tests: the SPM resource bundle.
        let url = Bundle.main.url(forResource: name, withExtension: "svg")
            ?? devBundleURL(name)
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        cache[harness] = image
        return image
    }

    private static var inkCache: [Harness: NSRect] = [:]

    /// The tight bounding box of the mark's actual ink, in the image's own
    /// coordinates — everything outside it is transparent padding baked into
    /// the SVG.
    ///
    /// The menu bar needs this. Drawn at its nominal size beside SF Symbols,
    /// a brand mark whose art fills 13 of its 16 points reads as a shrunken
    /// icon (AX, 2026-09-09: 「图标好小啊」), and the two brands do not carry
    /// the same padding, so a single hand-tuned fudge factor would fix one and
    /// break the other. Measuring it means a caller can fill the box it
    /// reserved with ink instead of with margin.
    ///
    /// `nil` when the glyph is missing or entirely transparent; the caller
    /// then draws the whole image and is no worse off than before.
    static func inkBounds(for harness: Harness) -> NSRect? {
        if let cached = inkCache[harness] { return cached }
        guard let image = image(for: harness),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0
        else { return nil }
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Pixels are top-down, the image's coordinates bottom-up.
        let sx = image.size.width / CGFloat(rep.pixelsWide)
        let sy = image.size.height / CGFloat(rep.pixelsHigh)
        let bounds = NSRect(
            x: CGFloat(minX) * sx,
            y: CGFloat(rep.pixelsHigh - 1 - maxY) * sy,
            width: CGFloat(maxX - minX + 1) * sx,
            height: CGFloat(maxY - minY + 1) * sy
        )
        inkCache[harness] = bounds
        return bounds
    }

    /// `Bundle.module` traps when the resource bundle is absent (the packaged
    /// app) — only touch it when the bundle actually exists on disk.
    private static func devBundleURL(_ name: String) -> URL? {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: name, withExtension: "svg")
    }
}

/// The tab's glyph: the provider brand mark for harness tabs (template-tinted
/// by the current foreground style), the SF grid for Overview, and an SF
/// fallback if a brand SVG ever fails to load.
struct ProviderGlyphView: View {
    let tab: ProviderTab
    var size: CGFloat = 12

    var body: some View {
        if let harness = tab.harness, let image = ProviderGlyph.image(for: harness) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: tab.symbol).font(.system(size: size - 1))
        }
    }
}
