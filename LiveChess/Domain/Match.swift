import Foundation
import Observation

/// Mutable, observable record of an in-progress chess match.
///
/// Holds the move history, every `Position` that resulted from each move
/// (so repetition detection has the data it needs) and a current `GameStatus`
/// that callers update via `apply(move:resulting:status:)`.
///
/// `Match` is intentionally `@MainActor`-isolated: it drives UI bindings
/// through `@Observable`. The pure `Position` / `Move` value types it stores
/// are `Sendable` and may travel to other actors freely.
@MainActor
@Observable
final class Match {

    private(set) var startPosition: Position
    private(set) var positions: [Position]
    private(set) var moves: [Move]
    private(set) var status: GameStatus

    init(startPosition: Position = .standardStart, status: GameStatus = .ongoing) {
        self.startPosition = startPosition
        self.positions = [startPosition]
        self.moves = []
        self.status = status
    }

    var currentPosition: Position { positions.last! }

    /// Records a move that has already been validated and applied by a
    /// rules engine. The match takes the resulting position and the engine's
    /// status verdict and stores them.
    func apply(move: Move, resulting: Position, status: GameStatus) {
        moves.append(move)
        positions.append(resulting)
        self.status = status
    }

    /// Resets the match to a new start position (default: standard).
    func reset(to position: Position = .standardStart, status: GameStatus = .ongoing) {
        startPosition = position
        positions = [position]
        moves = []
        self.status = status
    }

    /// Rolls back the most recent move so the match is back to the state
    /// it was in before that move was applied. `status` is restored to
    /// the snapshot the caller captured *before* applying. No-op if
    /// there are no moves yet.
    ///
    /// Used by `LichessMatchSession.submitMove(_:)` to undo an
    /// optimistic apply when the server rejects the POST. Local
    /// (`MatchCoordinator`) play never needs this since the rules
    /// engine validates locally before applying.
    func rollbackLastMove(restoringStatus status: GameStatus) {
        guard !moves.isEmpty else { return }
        moves.removeLast()
        positions.removeLast()
        self.status = status
    }
}
