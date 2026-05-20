import SwiftUI

/// Inline confirmation panel for HUDs hosted inside a RealityView
/// `Attachment` in an `ImmersiveSpace`.
///
/// On visionOS the system presentations — `.confirmationDialog`,
/// `.alert`, `.sheet` — have no window/scene to present into when the
/// presenting view lives inside an immersive-space attachment. The
/// `isPresented` binding flips to `true` but nothing ever renders, so a
/// "confirm before exit / resign / draw" button appears to do nothing.
///
/// Drop this row into the HUD's own control stack instead and drive it
/// from a pending-action state. It renders in place, where the HUD can
/// actually show it.
struct InlineConfirm: View {
    let title: String
    var message: String? = nil
    var confirmTitle: String
    var confirmRole: ButtonRole? = .destructive
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.xs) {
            Text(title)
                .font(.callout.weight(.semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Chess.Space.s) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(confirmTitle, role: confirmRole, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(Chess.Space.s)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: Chess.Radius.row))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
