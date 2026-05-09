import Foundation

/// `ChessAIEngine` that plays a uniformly-random legal move.
///
/// Used as the default opponent until `StockfishEngine` is wired up with its
/// NNUE network. Same protocol as the real engine, so swapping is a one-line
/// change in `ChessSceneView`.
actor RandomMoveAIEngine: ChessAIEngine {

    private let rules: any RulesEngine

    init(rules: any RulesEngine) {
        self.rules = rules
    }

    func bestMove(for position: Position, settings: AISettings) async throws -> Move {
        let legal = rules.legalMoves(in: position)
        guard let move = legal.randomElement() else {
            throw AIError.noMoveProduced
        }
        // Pretend to think. Capped at 800 ms so the game stays snappy even
        // when the user picked a long thinking time for the (future) real engine.
        let requestedMs = milliseconds(of: settings.thinkingTime) / 4
        let ms = min(800, max(150, requestedMs))
        try await Task.sleep(for: .milliseconds(ms))
        return move
    }

    func stop() async {
        // No long-running computation to cancel.
    }

    private func milliseconds(of duration: Duration) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return Int((seconds * 1000).rounded())
    }
}
