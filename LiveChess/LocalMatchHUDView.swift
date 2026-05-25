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

    /// Controls the game-over popup. Set to true automatically when
    /// the match ends; dismissed by the user tapping "New Game" inside it.
    @State private var showGameOverPopup = false

    // Single pending confirmation, rendered inline by `confirmPanel`.
    // `.confirmationDialog` can't present from an immersive-space
    // attachment, so we swap in an in-place row instead.
    private enum PendingConfirm: Equatable { case draw, resign, exit }
    @State private var pendingConfirm: PendingConfirm?

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
        // Watch for game-over: as soon as the match ends, show the popup.
        // We ignore subsequent changes (e.g. new game clears isGameOver)
        // because showGameOverPopup resets to false in the popup's button.
        .onChange(of: coordinator.match.status.isGameOver) { _, isOver in
            if isOver { showGameOverPopup = true }
        }
        // The popup is an overlay so it floats above the HUD panel itself.
        // It is NOT a .sheet — sheets don't work well in visionOS immersive
        // spaces. The overlay fills the whole screen and centers the card.
        .overlay {
            if showGameOverPopup {
                GameOverPopupView(
                    status: coordinator.match.status,
                    humanSide: humanSide,
                    elapsedText: elapsedText,
                    moveCount: coordinator.match.moves.count,
                    onNewGame: {
                        showGameOverPopup = false
                        coordinator.newGame()
                    },
                    onMainMenu: {
                        showGameOverPopup = false
                        Task {
                            appModel.activeSession = nil
                            await dismissImmersiveSpace()
                        }
                    }
                )
                // The popup needs to escape the 320pt HUD frame,
                // so we ignore it and expand to the full window.
                .frame(width: 480)
                .offset(x: 80) // centers it roughly over the board
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: Chess.Space.xs) {
            BrandMark(.iconOnly(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("Chess").foregroundStyle(Chess.Palette.accent)
                    Text("+").foregroundStyle(Chess.Palette.bronze)
                }
                .font(.system(.title3, design: .serif).weight(.semibold))
                Text("vs Stockfish")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        VStack(spacing: Chess.Space.xs) {
            Button {
                coordinator.newGame()
            } label: {
                Label("New game", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            // Draw + Resign — only meaningful while the game is in
            // progress. Stockfish doesn't negotiate over UCI, so for
            // local play both buttons end the match immediately.
            if !coordinator.match.status.isGameOver {
                HStack(spacing: Chess.Space.xs) {
                    Button {
                        pendingConfirm = .draw
                    } label: {
                        Label("Draw", systemImage: "circle.lefthalf.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(role: .destructive) {
                        pendingConfirm = .resign
                    } label: {
                        Label("Resign", systemImage: "flag.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

            if let placement {
                placementControls(placement)
            }

            environmentPickerButton

            Button(role: .destructive) {
                if coordinator.match.status.isGameOver {
                    Task {
                        appModel.activeSession = nil
                        await dismissImmersiveSpace()
                    }
                } else {
                    pendingConfirm = .exit
                }
            } label: {
                Label("Main menu", systemImage: "house.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if let pendingConfirm {
                confirmPanel(for: pendingConfirm)
            }
        }
        .animation(.snappy, value: pendingConfirm)
    }

    /// Move | Rotate toggle pair + Reposition button. Each toggle is
    /// independently deselectable — tap an armed mode again to disarm
    /// it and lock the board against accidental drags. Default is
    /// "neither armed", so the user has to opt in before a stray pinch
    /// on the frame can move the board.
    @ViewBuilder
    private func placementControls(_ placement: PlacementController) -> some View {
        HStack(spacing: Chess.Space.xs) {
            placementModeButton(
                placement: placement,
                mode: .move,
                title: "Move",
                icon: "arrow.up.and.down.and.arrow.left.and.right"
            )
            placementModeButton(
                placement: placement,
                mode: .rotate,
                title: "Rotate",
                icon: "arrow.triangle.2.circlepath"
            )
        }

        Button {
            placement.reposition()
        } label: {
            Label("Reposition", systemImage: "viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    /// One half of the Move|Rotate toggle pair. Modelled as a `Toggle`
    /// with `.toggleStyle(.button)` so the pressed/unpressed visual is
    /// handled by the system — the button capsule fills with the
    /// accent tint when armed, returns to the translucent glass look
    /// when disarmed. The custom binding gives the pair tri-state
    /// behaviour (Move on / Rotate on / neither): turning a toggle on
    /// arms its mode, turning it off (or arming the other) sets
    /// `dragMode` back to `nil`.
    @ViewBuilder
    private func placementModeButton(
        placement: PlacementController,
        mode: PlacementController.DragMode,
        title: String,
        icon: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { placement.dragMode == mode },
            set: { isOn in placement.dragMode = isOn ? mode : nil }
        )) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func confirmPanel(for action: PendingConfirm) -> some View {
        switch action {
        case .draw:
            InlineConfirm(
                title: "Agree to a draw?",
                message: "This will end the game in a draw.",
                confirmTitle: "Agree to draw",
                onConfirm: {
                    coordinator.agreeDraw()
                    pendingConfirm = nil
                },
                onCancel: { pendingConfirm = nil }
            )
        case .resign:
            InlineConfirm(
                title: "Resign the game?",
                message: "Your opponent will be awarded the win.",
                confirmTitle: "Resign",
                onConfirm: {
                    coordinator.resign(side: humanSide ?? .white)
                    pendingConfirm = nil
                },
                onCancel: { pendingConfirm = nil }
            )
        case .exit:
            InlineConfirm(
                title: "Exit to main menu?",
                message: "The current game will be lost.",
                confirmTitle: "Exit",
                onConfirm: {
                    Task {
                        appModel.activeSession = nil
                        await dismissImmersiveSpace()
                    }
                },
                onCancel: { pendingConfirm = nil }
            )
        }
    }

    private var environmentPickerButton: some View {
        Menu {
            ForEach(SceneEnvironment.allCases) { env in
                Button {
                    Task { await switchEnvironment(to: env) }
                } label: {
                    Label(env.displayName, systemImage: env.systemImage)
                    if env == appModel.selectedEnvironment {
                        Image(systemName: "checkmark")
                    }
                }
                .disabled(env == appModel.selectedEnvironment)
            }
        } label: {
            Label(
                appModel.selectedEnvironment.displayName,
                systemImage: appModel.selectedEnvironment.systemImage
            )
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    /// Swaps the immersive scene's environment. Same dismiss + re-open
    /// cycle the old toggle used; `pendingReopen` keeps the active
    /// session + the main-menu window state alive across the swap.
    private func switchEnvironment(to env: SceneEnvironment) async {
        guard env != appModel.selectedEnvironment else { return }
        appModel.selectedEnvironment = env
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

    // MARK: - Helpers

    /// Returns the Side the human is playing, or nil for draw/unknown.
    private var humanSide: Side? {
        if case .human = coordinator.white { return .white }
        if case .human = coordinator.black { return .black }
        return nil
    }

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

// MARK: - Game Over Popup

/// Full-screen centered card that appears when the match ends.
///
/// Shows:
///  - A large emoji + "You Won" / "You Lost" / "Draw"
///  - The reason (checkmate, stalemate, …)
///  - Move count + elapsed time
///  - "New Game" (primary) and "Main Menu" (destructive) buttons
///
/// It is presented as an `.overlay` on the HUD, not as a `.sheet`,
/// because visionOS immersive spaces don't support sheet presentation
/// from attachment views reliably.
@MainActor
private struct GameOverPopupView: View {

    let status: GameStatus
    let humanSide: Side?
    let elapsedText: String
    let moveCount: Int
    let onNewGame: () -> Void
    let onMainMenu: () -> Void

    // Controls the entry animation: the card fades + slides up on appear.
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Top: result emoji + headline ──────────────────────────
            VStack(spacing: 12) {
                Text(resultEmoji)
                    .font(.system(size: 64))

                Text(resultHeadline)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(resultColor)

                Text(resultSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 36)
            .padding(.horizontal, 28)

            Divider()
                .padding(.vertical, 20)

            // ── Middle: stats row ─────────────────────────────────────
            HStack(spacing: 0) {
                statCell(value: "\(moveCount)", label: "Moves")
                Divider().frame(height: 36)
                statCell(value: elapsedText, label: "Time")
            }
            .padding(.horizontal, 28)

            Divider()
                .padding(.vertical, 20)

            // ── Bottom: action buttons ────────────────────────────────
            VStack(spacing: 10) {
                Button {
                    onNewGame()
                } label: {
                    Label("New Game", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    onMainMenu()
                } label: {
                    Label("Main Menu", systemImage: "house.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 380)
        .glassBackgroundEffect()
        // Entry animation
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 24)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                isVisible = true
            }
        }
    }

    // MARK: - Derived values

    /// Figures out if the human won, lost, or drew.
    /// - If it's checkmate and the winner matches humanSide → won.
    /// - If it's checkmate and winner is the other side → lost.
    /// - Everything else (stalemate, draws, unknown) → draw.
    private enum Outcome { case won, lost, draw }

    private var outcome: Outcome {
        guard case .checkmate(let winner) = status else { return .draw }
        guard let human = humanSide else { return .draw }
        return winner == human ? .won : .lost
    }

    private var resultEmoji: String {
        switch outcome {
        case .won:  "🏆"
        case .lost: "💀"
        case .draw: "🤝"
        }
    }

    private var resultHeadline: String {
        switch outcome {
        case .won:  "You Won!"
        case .lost: "You Lost"
        case .draw: "Draw"
        }
    }

    private var resultSubtitle: String {
        switch status {
        case .checkmate(let winner):
            return winner == humanSide
                ? "Checkmate — your king is safe."
                : "Checkmate — your king has no escape."
        case .stalemate:
            return "No legal moves, but the king is not in check."
        case .drawByInsufficientMaterial:
            return "Not enough pieces to deliver checkmate."
        case .drawByFiftyMoveRule:
            return "50 moves without a capture or pawn advance."
        case .drawByThreefoldRepetition:
            return "The same position repeated three times."
        default:
            return ""
        }
    }

    private var resultColor: Color {
        switch outcome {
        case .won:  .green
        case .lost: .red
        case .draw: .secondary
        }
    }

    @ViewBuilder
    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
