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
    /// The underlying engine process never reached the ready-to-search state
    /// after `start`. Usually a sign the engine binary is missing or
    /// crashed during the UCI handshake.
    case engineUnavailable
    /// The engine completed its search without emitting a `bestmove`. Should
    /// be impossible against a non-terminal position; treated as a fault.
    case noMoveProduced
    /// The engine emitted a `bestmove` we couldn't parse as long-algebraic
    /// UCI (`e2e4`, `e7e8q`). The raw payload is included for diagnostics.
    case invalidEngineResponse(String)
    /// The engine didn't respond within the search-time budget plus a grace
    /// period. The actor will still attempt to send `stop` so the engine
    /// returns to an idle state for the next request.
    case timedOut
}
