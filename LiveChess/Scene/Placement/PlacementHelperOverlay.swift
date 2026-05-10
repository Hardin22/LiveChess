import SwiftUI

/// Tiny floating glass pill that shows the placement controller's
/// helper message above the chessboard. Hides itself entirely when
/// `controller.helperMessage == nil` so it doesn't pollute the scene
/// once the board is settled.
///
/// Used as a `RealityView` attachment positioned ~45 cm above the
/// board's centre — far enough to be readable, close enough to be
/// associated with the board (vs feeling like a system-level overlay).
@MainActor
struct PlacementHelperOverlay: View {

    let controller: PlacementController?

    var body: some View {
        if let controller, let message = controller.helperMessage {
            HStack(spacing: 10) {
                icon(for: controller.state)
                    .font(.callout)
                Text(message)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackgroundEffect()
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeOut(duration: 0.2), value: message)
        }
    }

    @ViewBuilder
    private func icon(for state: PlacementController.State) -> some View {
        switch state {
        case .starting, .searching, .repositioning:
            Image(systemName: "viewfinder")
                .symbolEffect(.pulse, options: .repeating)
        case .placed, .unavailable:
            Image(systemName: "hand.draw")
        }
    }
}
