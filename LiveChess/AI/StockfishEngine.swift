import Foundation
import ChessKitEngine

/// `ChessAIEngine` implementation backed by Stockfish via `chesskit-engine`.
///
/// Wraps a single `ChessKitEngine.Engine` instance for the lifetime of this
/// actor. The engine is lazily booted on the first `bestMove` call (UCI
/// handshake → `uciok` → `isready` → `readyok` → ready). Subsequent calls
/// reuse the running process.
///
/// - Note: chesskit-engine bundles Stockfish but does *not* bundle the NNUE
///   network files. Without them, Stockfish runs in classical evaluation
///   mode — fully legal moves, slightly lower strength. That trade is fine
///   for the MVP.
actor StockfishEngine: ChessAIEngine {

    private let engine = Engine(type: .stockfish)
    private var isStarted = false

    init() {}

    func bestMove(for position: Position, settings: AISettings) async throws -> Move {
        try await ensureStarted()

        await engine.send(
            command: .setoption(id: "Skill Level", value: "\(settings.skillLevel)")
        )
        await engine.send(command: .position(.fen(position.fen)))
        await engine.send(command: .go(movetime: milliseconds(of: settings.thinkingTime)))

        guard let stream = await engine.responseStream else {
            throw AIError.engineUnavailable
        }
        for await response in stream {
            if case let .bestmove(uciMove, _) = response {
                guard let move = Move(uci: uciMove) else {
                    throw AIError.invalidEngineResponse(uciMove)
                }
                return move
            }
        }
        throw AIError.noMoveProduced
    }

    func stop() async {
        await engine.stop()
        isStarted = false
    }

    // MARK: - Private

    private func ensureStarted() async throws {
        if isStarted { return }
        await engine.start()
        // The engine flips `isRunning` to `true` only after the
        // uci → uciok → isready → readyok handshake completes.
        // Poll briefly with a hard ceiling so a stuck handshake doesn't hang.
        for _ in 0..<200 {
            if await engine.isRunning {
                isStarted = true
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AIError.engineUnavailable
    }

    private func milliseconds(of duration: Duration) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return max(50, Int((seconds * 1000).rounded()))
    }
}
