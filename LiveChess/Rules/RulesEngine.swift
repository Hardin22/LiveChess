import Foundation

/// Pluggable chess rules engine. Validates moves, generates legal moves,
/// applies moves to positions, and reports the resulting game status.
///
/// The protocol is intentionally pure: implementations must not mutate any
/// shared state and must be safe to call from any concurrency domain.
protocol RulesEngine: Sendable {

    /// All legal moves available to the side-to-move in `position`.
    /// Pawn promotions are expanded into one move per promotion piece (queen, rook, bishop, knight).
    func legalMoves(in position: Position) -> [Move]

    /// Convenience overload that filters `legalMoves(in:)` by origin square.
    func legalMoves(from square: Square, in position: Position) -> [Move]

    /// Applies `move` to `position` and returns the resulting position.
    /// Throws `RulesError.illegalMove` if the move is not legal.
    func apply(_ move: Move, to position: Position) throws -> Position

    /// Evaluates the game-ending status of `position`. `history` should contain
    /// every position seen so far (including `position`) to enable threefold-repetition detection.
    func status(of position: Position, history: [Position]) -> GameStatus
}

enum RulesError: Error, Sendable, Equatable {
    case invalidPosition
    case illegalMove
    case missingPromotion
    case engineFailure
}
