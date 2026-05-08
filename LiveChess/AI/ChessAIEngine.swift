import Foundation

/// Pluggable chess AI. Conforming types are actors so they can serialise
/// access to a single underlying engine process safely.
protocol ChessAIEngine: Actor {

    /// Returns the engine's choice of move from `position`. Throws if the
    /// engine is unavailable or fails to produce a legal move.
    func bestMove(for position: Position, settings: AISettings) async throws -> Move

    /// Asks the engine to abort any in-progress search. Best-effort.
    func stop() async
}

enum AIError: Error, Sendable, Equatable {
    case engineUnavailable
    case noMoveProduced
    case invalidEngineResponse(String)
}
