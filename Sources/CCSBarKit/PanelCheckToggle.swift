import SwiftUI

/// A leading checkbox for the options grid.
///
/// The grid shipped with trailing switches and AX said it did not look right
/// (2026-09-14: 「感觉不好看」). The reason is structural, not decorative: a
/// switch needs a right edge to sit against, and two per row means two right
/// edges — so the first column's switch lands in the MIDDLE of the row, a
/// saturated blue slab with the next option's label starting a few points
/// later. Four of them at two different x positions is what made the block
/// look busy while being half as tall.
///
/// A checkbox is a leading control, so both columns start at the same two x
/// positions and the ragged ends of the labels fall where nothing has to line
/// up. It is also the control macOS itself uses for a dense list of independent
/// options, and it keeps the property that made a switch beat a capsule here:
/// AppKit draws it with an accent fill AND a glyph, two channels that survive
/// being composited over a frosted panel sampling the desktop.
///
/// Like `PanelSwitchToggle`, it swaps to a drawn lookalike under
/// `snapshotRender` — `ImageRenderer` draws only SwiftUI, and an AppKit-backed
/// control renders as the yellow missing-view placeholder.
struct PanelCheckToggle<Label: View>: View {
    @Environment(\.snapshotRender) private var snapshotRender
    let isOn: Binding<Bool>
    @ViewBuilder let label: () -> Label

    var body: some View {
        if snapshotRender {
            // 5pt, which is what AppKit puts between an NSButton checkbox and
            // its title — the drawn version has to land in the same place as
            // the real one or the snapshots stop describing the app.
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(isOn.wrappedValue ? Color.accentColor : Color.primary.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3.5)
                            .strokeBorder(Color.primary.opacity(isOn.wrappedValue ? 0 : 0.22), lineWidth: 1)
                    }
                    .overlay {
                        if isOn.wrappedValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                label()
            }
        } else {
            Toggle(isOn: isOn, label: label)
                .toggleStyle(.checkbox)
        }
    }
}
