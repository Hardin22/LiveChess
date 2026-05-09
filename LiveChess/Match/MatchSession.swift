import Foundation

/// Shared abstraction over an in-progress chess match, regardless of where
/// the moves come from. `MatchCoordinator` (local human vs AI) and
/// `LichessMatchSession` (human vs remote opponent over the Board API)
/// both conform.
///
/// The protocol is intentionally minimal — it carries only what the
/// scene host (`ChessSceneView`) needs to render a board and handle
/// drag-to-move. Everything specific to either flow (`isAIThinking`,
/// `clock`, `opponent`, `result`, …) stays on the concrete type and the
/// HUD branches on it as needed.
@MainActor
protocol MatchSession: AnyObject {

    /// Domain state of the game so far. Same shape regardless of source.
    var match: Match { get }

    /// True iff it's the human player's turn AND the game is still in
    /// progress AND the session isn't blocked on something else (an AI
    /// computing locally, or a network hop in flight).
    ///
    /// The drag handler reads this before allowing pickup; the HUD reads
    /// it to gate the "your move" indicator.
    var isHumanTurn: Bool { get }

    /// Legal moves from a square in the current position. Computed locally
    /// for both flows — the local rules engine is authoritative for the
    /// drag UI even on online games (the server validates the eventual
    /// move and rejects illegal ones).
    func legalMoves(from square: Square) -> [Move]

    /// Submit a move from the human player. Implementations decide the
    /// semantics: the local coordinator applies it through the rules
    /// engine and triggers the AI; the Lichess session applies it
    /// optimistically and POSTs to `/api/board/game/{id}/move/{uci}`,
    /// rolling back on a 4xx.
    func submitMove(_ move: Move) async
}
