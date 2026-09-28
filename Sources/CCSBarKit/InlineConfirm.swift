import SwiftUI

/// A confirm that opens inside the element that asked for it (an account row,
/// a chain member), instead of a tinted banner at the panel top where the eye
/// has to go looking for it. One line of consequence, then Cancel and the
/// action, which carries the action's own name and severity hue. Return
/// confirms, Esc cancels.
struct InlineConfirm: View {
    let message: String
    let action: String
    let tint: Color
    var disabled = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(action, action: onConfirm)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
        }
        .padding(.top, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// The armed confirm an account row owns, if any. Pure over the model's pending
/// state so the routing (which row, which copy) is unit-tested.
enum RowConfirm: Equatable {
    case delete(String)
    case reset(String)
    case remove(String)

    @MainActor
    static func armed(for name: String, in model: StatusModel) -> RowConfirm? {
        if model.pendingDelete == name, let prompt = model.pendingDeletePrompt {
            return .delete(prompt)
        }
        if model.pendingReset == name, let prompt = model.pendingResetPrompt {
            return .reset(prompt)
        }
        if model.pendingRemoval == name, !model.pendingRemovalFromChain,
           let prompt = model.pendingRemovalPrompt
        {
            return .remove(prompt)
        }
        return nil
    }

    /// The hue the row's outline and the action button share.
    var tint: Color {
        switch self {
        case .delete: Theme.danger
        case .reset: Theme.codex
        case .remove: Theme.warning
        }
    }
}
