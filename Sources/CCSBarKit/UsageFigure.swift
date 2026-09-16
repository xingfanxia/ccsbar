import SwiftUI

/// The number beside a usage bar, worded when it is counting the other way.
///
/// A percentage next to a usage bar means SPENT everywhere else in this fleet —
/// clauth's TUI, ccu, and ccsbar's own default. `FleetDisplay.remainingKey`
/// flips this surface to count what is left, and the flip used to be invisible:
/// "7d 0%" is a true reading of an exhausted account in remaining mode and of
/// an untouched one in spent mode, and nothing in the row said which. AX hit
/// exactly that on 2026-09-16, reading three codex rows at "0%" beside three
/// "week spent" pills. The bar cannot settle it either: at both ends of the
/// axis the two modes draw the same shape, so only a word can.
///
/// VoiceOver has said "0 percent left" here since the preference shipped. This
/// is the sighted half of that sentence.
///
/// Only the flipped axis is worded. An unmarked number is the convention every
/// other surface reports on, so the word carries the whole message — "this one
/// is not that". Wording both axes would print a permanent "used" over the
/// default the preference is off for, which is chrome that says nothing.
struct UsageFigure: View {
    /// ALWAYS the spent percentage, whichever axis is being read — the same
    /// contract as `UsageBar.pct`, so a row cannot hand its number and its bar
    /// two different axes. `nil` prints an em dash: no reading, not zero.
    let pct: Double?
    let remaining: Bool
    var font: Font = Theme.figure
    /// The suffix is a unit, not a second figure: it rides a step below the
    /// number it annotates and never competes with it.
    var suffixFont: Font = Theme.micro
    /// Tint for the number. `nil` keeps the inherited foreground, which is what
    /// the hero row wants (primary) where the mini rows pass `.secondary`.
    var color: Color?
    /// False for a figure whose group has already been worded — the 7d/Fable
    /// minis sit directly under a hero that says "58% left" and repeating it
    /// costs twice: three "left"s in one account row, and a fatter text column
    /// that eats the flexible bars beside it, so a 7d bar and a Fable bar
    /// stopped being comparable at a glance. The axis is stated once per group,
    /// by the figure that leads it.
    var wordsAxis = true

    /// The two runs the figure prints. Pure and `nonisolated` so the wording
    /// rule is assertable without a render: the panel has no snapshot test that
    /// reads text, and "which axis is this number on" is precisely the question
    /// that was wrong on screen.
    nonisolated static func parts(pct: Double?, remaining: Bool) -> (figure: String, suffix: String?) {
        guard let pct else { return ("—", nil) }
        return ("\(FleetDisplay.shown(pct, remaining: remaining))%",
                remaining ? FleetDisplay.axisWord(remaining: true) : nil)
    }

    var body: some View {
        let (figure, unwordedSuffix) = Self.parts(pct: pct, remaining: remaining)
        let suffix = wordsAxis ? unwordedSuffix : nil
        var text = Text(figure).font(font)
        if let color { text = text.foregroundStyle(color) }
        if let suffix {
            text = text + Text(" \(suffix)").font(suffixFont).foregroundStyle(.secondary)
        }
        // One accessibility element, spoken the way the row has always spoken
        // it — the suffix must not become a second stop for a screen reader.
        return text.accessibilityLabel(
            pct.map { "\(FleetDisplay.shown($0, remaining: remaining)) percent \(FleetDisplay.axisWord(remaining: remaining))" }
                ?? "no reading"
        )
    }
}
