import SwiftUI

/// Set by `Snapshot.panelSurface` so views can swap AppKit-backed controls for
/// pure-SwiftUI stand-ins: `ImageRenderer` draws only SwiftUI content, and an
/// NSSwitch-backed `.toggleStyle(.switch)` renders as the yellow missing-view
/// placeholder in README snapshots.
private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

/// The panel's switch-row toggle: a real mini NSSwitch in the live app, a
/// hand-drawn lookalike under `snapshotRender` so `ImageRenderer` can draw it.
struct PanelSwitchToggle<Label: View>: View {
    @Environment(\.snapshotRender) private var snapshotRender
    let isOn: Binding<Bool>
    @ViewBuilder let label: () -> Label

    var body: some View {
        if snapshotRender {
            HStack(spacing: 10) {
                label()
                Capsule()
                    .fill(isOn.wrappedValue ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 31, height: 18)
                    .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                        Circle().fill(.white)
                            .frame(width: 16, height: 16)
                            .padding(.horizontal, 1)
                            .shadow(radius: 0.5)
                    }
            }
        } else {
            Toggle(isOn: isOn, label: label)
                .toggleStyle(.switch).controlSize(.mini)
        }
    }
}
