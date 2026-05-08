import Foundation
import Observation

/// Orchestrates turn flow between a human and an AI side.
///
/// The coordinator owns the `Match` and applies moves to it after each side
/// produces one. Humans submit via `submitHumanMove(_:)`. AI moves are fetched
/// asynchronously: when it becomes the AI's turn, the coordinator schedules
/// a `Task` on the engine actor and applies the result back on the main
/// actor when it arrives. `isAIThinking` flips around that round-trip so UI
/// can show a spinner.
///
/// A future Lichess remote opponent fits the same shape: introduce a third
/// `SideController` case and a network-backed `ChessAIEngine`-shaped type.
@MainActor
@Observable
final class MatchCoordinator {

    enum SideController: Hashable, Sendable {
        case human
        case ai(AISettings)
    }

    let match: Match
    private let rules: any RulesEngine
    private let ai: any ChessAIEngine

    private(set) var white: SideController
    private(set) var black: SideController
    private(set) var isAIThinking: Bool = false
    private(set) var lastError: Error?

    /// Exposed so tests can `await coordinator.aiTask?.value` deterministically.
    /// In production code you should not need to touch this directly.
    private(set) var aiTask: Task<Void, Never>?

    init(
        match: Match,
        rules: any RulesEngine,
        ai: any ChessAIEngine,
        white: SideController,
        black: SideController
    ) {
        self.match = match
        self.rules = rules
        self.ai = ai
        self.white = white
        self.black = black
    }

    /// Begins the match. If the side-to-move is the AI (e.g. human plays
    /// black), this kicks off the AI's first move.
    func start() {
        triggerAIIfNeeded()
    }

    /// Submits a move from the human player. No-op if it's not a human's
    /// turn, the game is over, or the move is illegal (sets `lastError`).
    func submitHumanMove(_ move: Move) {
        guard !match.status.isGameOver else { return }
        guard case .human = controller(for: match.currentPosition.sideToMove) else { return }
        performMove(move)
        triggerAIIfNeeded()
    }

    /// Resets the match to the standard starting position, optionally swapping
    /// which colour the human plays.
    func newGame(humanColor: Side? = nil) {
        aiTask?.cancel()
        aiTask = nil
        isAIThinking = false
        lastError = nil

        if let humanColor {
            let aiSettings = currentAISettings()
            white = humanColor == .white ? .human : .ai(aiSettings)
            black = humanColor == .black ? .human : .ai(aiSettings)
        }

        match.reset()
        triggerAIIfNeeded()
    }

    /// Convenience for tests that need to await the in-flight AI task.
    func waitForAI() async {
        await aiTask?.value
    }

    // MARK: - Private

    private func performMove(_ move: Move) {
        do {
            let resulting = try rules.apply(move, to: match.currentPosition)
            let allPositions = match.positions + [resulting]
            let status = rules.status(of: resulting, history: allPositions)
            match.apply(move: move, resulting: resulting, status: status)
        } catch {
            lastError = error
        }
    }

    private func triggerAIIfNeeded() {
        guard !match.status.isGameOver else { return }
        let side = match.currentPosition.sideToMove
        guard case .ai(let settings) = controller(for: side) else { return }
        guard !isAIThinking else { return }

        let snapshotPosition = match.currentPosition
        let aiRef = ai

        isAIThinking = true
        aiTask = Task { @MainActor [weak self] in
            let move: Move?
            let failure: Error?
            do {
                move = try await aiRef.bestMove(for: snapshotPosition, settings: settings)
                failure = nil
            } catch {
                move = nil
                failure = error
            }

            guard let self else { return }
            // Flip the spinner OFF before chaining; otherwise `triggerAIIfNeeded`
            // would short-circuit on the `!isAIThinking` guard, breaking AI-vs-AI.
            self.isAIThinking = false
            guard !Task.isCancelled else { return }

            if let move {
                self.performMove(move)
                self.triggerAIIfNeeded()
            } else if let failure {
                self.lastError = failure
            }
        }
    }

    private func controller(for side: Side) -> SideController {
        side == .white ? white : black
    }

    private func currentAISettings() -> AISettings {
        if case .ai(let s) = white { return s }
        if case .ai(let s) = black { return s }
        return AISettings()
    }
}
