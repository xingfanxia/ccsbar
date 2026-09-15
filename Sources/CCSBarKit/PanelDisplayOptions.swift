import SwiftUI

/// The panel's display preferences, as data rather than as five hand-written
/// rows.
///
/// They were five stacked full-width switch rows, four of which opened with the
/// same three words — "Menu bar shows disarmed mark", "…shows active account",
/// "…shows remaining", "…shows bars". That is one sentence with the last word
/// changed, which is why the block read as long and undifferentiated, and AX
/// asked for it to be compact (2026-09-14: 「这边可以不要每个一行，可以一行两
/// 个或者你怎么设计一下更紧凑」).
///
/// As a list they can be laid out however the panel wants, and the copy is in
/// one place where it can be read as a set. Each label names the THING the
/// preference controls; the tooltip says what happens.
enum PanelDisplayOption: String, CaseIterable, Identifiable {
    /// Mark the menu bar when no chain will rotate.
    case disarmed
    /// Read the active account instead of averaging the whole pool.
    case activeOnly
    /// Count what is left rather than what is spent.
    case remaining
    /// Draw a bar beside each menu-bar figure.
    case bars

    var id: String { rawValue }

    /// The `@AppStorage` key. Kept on `FleetDisplay`, which already owns them
    /// and is where the menu-bar label reads them.
    var key: String {
        switch self {
        case .disarmed: return FleetDisplay.disarmedKey
        case .activeOnly: return FleetDisplay.activeOnlyKey
        case .remaining: return FleetDisplay.remainingKey
        case .bars: return FleetDisplay.barsKey
        }
    }

    /// The value a fresh install starts from. Only the disarmed mark is on:
    /// a chain that will not rotate is a real degraded state and the menu bar
    /// is where it is cheap to notice.
    var defaultsOn: Bool { self == .disarmed }

    var symbol: String {
        switch self {
        case .disarmed: return "bolt.slash"
        case .activeOnly: return "person.crop.circle"
        case .remaining: return "arrow.left.arrow.right.circle"
        case .bars: return "chart.bar"
        }
    }

    /// Names the thing, not the surface. Four labels that all began "Menu bar
    /// shows…" were the problem.
    ///
    /// Kept short enough to survive a half-width cell at this type size —
    /// "Active account only" truncated to "Active account o…", and a label that
    /// loses its last word is worse than one that never had it. The tooltip
    /// carries the rest.
    ///
    /// "Active, not pool" names the OFF state inside the label. A switch can
    /// only ever name one of its two states, and this preference's off-state is
    /// a real thing with a real name — the pool average — that nothing in the
    /// app had ever said out loud. Naming it costs four characters; the obvious
    /// alternative, a segmented Pool | Active picker, costs a full-width row in
    /// the one region whose complaint is height.
    var label: String {
        switch self {
        case .disarmed: return "Disarmed warning"
        case .activeOnly: return "Active, not pool"
        case .remaining: return "Count what's left"
        case .bars: return "Usage bars"
        }
    }

    /// What happens when it is on. Says which surfaces are affected, because
    /// `remaining` governs two of them and the others only govern one.
    var help: String {
        switch self {
        case .disarmed:
            return "Mark the menu bar when no chain will rotate. Off hides the mark; the chain stays disarmed either way."
        case .activeOnly:
            return "The menu bar reads the account you're on, instead of averaging that harness's whole pool."
        case .remaining:
            return "Show what's left instead of what's spent — in the menu bar and in the account rows."
        case .bars:
            return "Draw a small usage bar beside each menu-bar figure."
        }
    }
}
