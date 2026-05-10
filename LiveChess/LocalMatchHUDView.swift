import SwiftUI
import Combine

/// Floating glass-style information panel anchored next to the chessboard.
///
/// Surfaces everything the player needs at a glance during a game without
/// distracting from the board itself:
///
/// - Whose turn it is (with a colour dot for the side-to-move).
/// - Live "Stockfish sta pensando…" indicator while the AI is computing.
/// - Subtle warning when one of the kings is in check.
/// - Move counter + the last move in long algebraic (`e2e4`) notation.
/// - Elapsed match clock that pauses on game-over.
/// - Final result + reason at the end of a match.
/// - "Nuova partita" button that hands the human a fresh starting position.
///
/// The panel is rendered at fixed size (300 pt wide, ~auto height) so the
/// scene host can place it on a single attachment quad without surprises.
@MainActor
struct LocalMatchHUDView: View {

    @Bindable var coordinator: MatchCoordinator
    /// Optional — drives the "Move board" button. Nil only in the
    /// SwiftUI preview; in real scenes the placement controller is
    /// always set up by `ChessSceneView.make`.
    var placement: PlacementController?

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    /// Wall-clock time the current match started. Reset on `newGame()`.
    @State private var matchStartedAt: Date = .now
    @State private var now: Date = .now
    /// Drives the elapsed-time read-out.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            statusSection
            if !coordinator.match.moves.isEmpty {
                Divider()
                moveLog
            }
            if coordinator.match.status.isGameOver {
                Divider()
                gameOverSection
            }
            Divider()
            controls
        }
        .padding(20)
        .frame(width: 320, alignment: .topLeading)
        .glassBackgroundEffect()
        .onReceive(timer) { now = $0 }
        .onChange(of: coordinator.match.moves.count) { _, count in
            // Reset the clock when the match is reset (move count drops to 0).
            if count == 0 {
                matchStartedAt = .now
                now = .now
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LiveChess")
                .font(.title3.weight(.semibold))
            Text("vs Stockfish")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 10) {
            sideDot(coordinator.match.currentPosition.sideToMove)
            VStack(alignment: .leading, spacing: 2) {
                Text(turnTitle)
                    .font(.callout.weight(.medium))
                if let detail = turnDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if coordinator.isAIThinking {
                ProgressView().controlSize(.small)
            }
        }

        if case .check(let side) = coordinator.match.status, !coordinator.match.status.isGameOver {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(side == .white ? "White is in check" : "Black is in check")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }

        HStack(spacing: 6) {
            Image(systemName: "clock")
                .imageScale(.small)
            Text(elapsedText)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var moveLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Move")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("#\(coordinator.match.moves.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let last = coordinator.match.moves.last {
                Text(last.uci)
                    .font(.title3.monospaced().weight(.medium))
            }
        }
    }

    @ViewBuilder
    private var gameOverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: gameOverSymbol)
                Text(gameOverTitle)
                    .font(.headline)
            }
            .foregroundStyle(gameOverTint)
            Text(gameOverReason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                coordinator.newGame()
            } label: {
                Label("New game", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let placement {
                Button {
                    placement.reposition()
                } label: {
                    Label("Move board", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            environmentToggleButton
        }
    }

    /// Switches the immersive between AR (mixed reality, real
    /// passthrough) and the bundled virtual room. The scene needs to
    /// rebuild to pick up the new immersionStyle + environment, so the
    /// toggle dismisses + re-opens the immersive.
    private var environmentToggleButton: some View {
        Button {
            Task { await toggleEnvironment() }
        } label: {
            Label(
                appModel.virtualEnvironmentEnabled ? "Switch to AR" : "Virtual room",
                systemImage: appModel.virtualEnvironmentEnabled ? "arkit" : "cube.transparent"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func toggleEnvironment() async {
        let willBeVirtual = !appModel.virtualEnvironmentEnabled
        appModel.virtualEnvironmentEnabled = willBeVirtual
        // Tell the scene's onDisappear to keep the active session
        // alive across the dismiss-and-reopen — we're not really
        // closing the game, just rebuilding the immersive shell.
        appModel.pendingReopen = true
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        default:
            appModel.immersiveSpaceState = .closed
            appModel.pendingReopen = false
        }
    }

    // MARK: - Derived strings / styles

    private var turnTitle: String {
        if coordinator.match.status.isGameOver { return "Game over" }
        if coordinator.isAIThinking { return "Stockfish is thinking…" }
        let side = coordinator.match.currentPosition.sideToMove
        let isHuman = isHumanSide(side)
        if isHuman { return "Your turn" }
        return "Stockfish's turn"
    }

    private var turnDetail: String? {
        if coordinator.match.status.isGameOver { return nil }
        let side = coordinator.match.currentPosition.sideToMove
        return side == .white ? "White" : "Black"
    }

    private func isHumanSide(_ side: Side) -> Bool {
        let controller = side == .white ? coordinator.white : coordinator.black
        if case .human = controller { return true }
        return false
    }

    private var elapsedText: String {
        let interval = max(0, now.timeIntervalSince(matchStartedAt))
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var gameOverSymbol: String {
        switch coordinator.match.status {
        case .checkmate: "flag.checkered"
        case .stalemate, .drawByInsufficientMaterial,
             .drawByFiftyMoveRule, .drawByThreefoldRepetition: "equal.circle"
        default: "info.circle"
        }
    }

    private var gameOverTitle: String {
        switch coordinator.match.status {
        case .checkmate(let winner):
            return winner == .white ? "Checkmate — White wins" : "Checkmate — Black wins"
        case .stalemate:                  return "Stalemate"
        case .drawByInsufficientMaterial: return "Draw"
        case .drawByFiftyMoveRule:        return "Draw"
        case .drawByThreefoldRepetition:  return "Draw"
        default:                          return "Game over"
        }
    }

    private var gameOverReason: String {
        switch coordinator.match.status {
        case .checkmate:
            return "The opponent's king has no legal moves and is in check."
        case .stalemate:
            return "The player to move has no legal moves but the king is not in check."
        case .drawByInsufficientMaterial:
            return "Insufficient material to deliver checkmate."
        case .drawByFiftyMoveRule:
            return "50 moves without a capture or a pawn advance."
        case .drawByThreefoldRepetition:
            return "The same position has been reached three times."
        default:
            return ""
        }
    }

    private var gameOverTint: Color {
        switch coordinator.match.status {
        case .checkmate: .accentColor
        case .stalemate, .drawByInsufficientMaterial,
             .drawByFiftyMoveRule, .drawByThreefoldRepetition: .secondary
        default: .primary
        }
    }

    private func sideDot(_ side: Side) -> some View {
        Circle()
            .fill(side == .white ? Color.white : Color.black)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.secondary.opacity(0.6), lineWidth: 0.5))
    }
}
