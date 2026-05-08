import Foundation
@testable import LiveChess

/// Deterministic test double for `RulesEngine`. Tests configure the canned
/// responses and inspect call counts.
final class MockRulesEngine: RulesEngine, @unchecked Sendable {

    var legalMovesValue: [Move] = []
    var statusValue: GameStatus = .ongoing
    var applyError: RulesError?

    private(set) var legalMovesCallCount = 0
    private(set) var applyCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var lastAppliedMove: Move?

    func legalMoves(in position: Position) -> [Move] {
        legalMovesCallCount += 1
        return legalMovesValue
    }

    func legalMoves(from square: Square, in position: Position) -> [Move] {
        legalMovesValue.filter { $0.from == square }
    }

    func apply(_ move: Move, to position: Position) throws -> Position {
        applyCallCount += 1
        lastAppliedMove = move
        if let applyError {
            throw applyError
        }
        // Default: return same board with sideToMove flipped, fullmove incremented if black just moved.
        var resulting = position
        resulting.sideToMove = position.sideToMove.opponent
        if position.sideToMove == .black {
            resulting.fullmoveNumber += 1
        }
        return resulting
    }

    func status(of position: Position, history: [Position]) -> GameStatus {
        statusCallCount += 1
        return statusValue
    }
}
