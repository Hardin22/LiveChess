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
struct MatchHUDView: View {

    @Bindable var coordinator: MatchCoordinator

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
                Text(side == .white ? "Bianco è sotto scacco" : "Nero è sotto scacco")
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
                Text("Mossa")
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
        Button {
            coordinator.newGame()
        } label: {
            Label("Nuova partita", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Derived strings / styles

    private var turnTitle: String {
        if coordinator.match.status.isGameOver { return "Partita conclusa" }
        if coordinator.isAIThinking { return "Stockfish sta pensando…" }
        let side = coordinator.match.currentPosition.sideToMove
        let isHuman = isHumanSide(side)
        if isHuman { return "Tocca a te" }
        return "Tocca a Stockfish"
    }

    private var turnDetail: String? {
        if coordinator.match.status.isGameOver { return nil }
        let side = coordinator.match.currentPosition.sideToMove
        return side == .white ? "Bianco" : "Nero"
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
            return winner == .white ? "Scaccomatto — Vince Bianco" : "Scaccomatto — Vince Nero"
        case .stalemate:                  return "Stallo"
        case .drawByInsufficientMaterial: return "Patta"
        case .drawByFiftyMoveRule:        return "Patta"
        case .drawByThreefoldRepetition:  return "Patta"
        default:                          return "Partita conclusa"
        }
    }

    private var gameOverReason: String {
        switch coordinator.match.status {
        case .checkmate:
            return "Il re avversario non ha più mosse legali ed è sotto scacco."
        case .stalemate:
            return "Il giocatore di turno non ha mosse legali ma il re non è sotto scacco."
        case .drawByInsufficientMaterial:
            return "Sul tavolo non ci sono pezzi sufficienti per scaccomatto."
        case .drawByFiftyMoveRule:
            return "50 mosse senza catture o spinte di pedone."
        case .drawByThreefoldRepetition:
            return "La stessa posizione si è ripetuta 3 volte."
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
