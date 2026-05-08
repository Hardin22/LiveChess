import Foundation
@testable import LiveChess

/// Test double for `ChessAIEngine`. Returns a queue of pre-set moves with an
/// optional artificial delay so tests can observe `isAIThinking` transitions.
actor MockAIEngine: ChessAIEngine {

    private var movesQueue: [Move]
    private var thinkingDelay: Duration
    private var failureToThrow: Error?
    private(set) var bestMoveCallCount = 0
    private(set) var stopCallCount = 0

    init(moves: [Move] = [], thinkingDelay: Duration = .zero, failure: Error? = nil) {
        self.movesQueue = moves
        self.thinkingDelay = thinkingDelay
        self.failureToThrow = failure
    }

    func bestMove(for position: Position, settings: AISettings) async throws -> Move {
        bestMoveCallCount += 1
        if thinkingDelay > .zero {
            try await Task.sleep(for: thinkingDelay)
        }
        if let failureToThrow { throw failureToThrow }
        guard !movesQueue.isEmpty else {
            throw AIError.noMoveProduced
        }
        return movesQueue.removeFirst()
    }

    func stop() async {
        stopCallCount += 1
    }

    // MARK: - Test setters

    func enqueue(_ move: Move) {
        movesQueue.append(move)
    }

    func setDelay(_ delay: Duration) {
        thinkingDelay = delay
    }

    func setFailure(_ error: Error?) {
        failureToThrow = error
    }
}
