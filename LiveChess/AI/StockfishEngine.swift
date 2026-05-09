import Foundation
import ChessKitEngine

/// `ChessAIEngine` implementation backed by Stockfish 17 via `chesskit-engine`.
///
/// The engine binary lives inside the `ChessKitEngineCore` SPM target and is
/// driven over UCI. The two NNUE networks Stockfish 17 expects
/// (`nn-1111cefa1111.nnue` big and `nn-37f18f62d772.nnue` small) ship in
/// the app bundle and are picked up automatically by `chesskit-engine`'s
/// initial-setup loop — without them Stockfish falls back to its
/// (much weaker) classical evaluator.
///
/// Lifecycle:
///   * The underlying `Engine` is lazily started on the first `bestMove(...)`
///     call, runs through the UCI handshake (`uci → uciok → isready → readyok`)
///     and stays up for the rest of the actor's lifetime.
///   * Each request sets the per-game options that may have changed
///     (`Skill Level`), pushes the FEN, and sends `go movetime <ms>`.
///   * Cancellation (`Task.cancel()` on the calling task) sends `stop` to
///     Stockfish so it returns to an idle state instead of finishing the
///     current search; the resulting `bestmove` is consumed and discarded
///     so it doesn't pollute the next request's response stream.
///   * A safety timeout (`thinkingTime` + 3 s) prevents a stuck engine from
///     blocking the match coordinator forever.
actor StockfishEngine: ChessAIEngine {

    private let engine = Engine(type: .stockfish)
    private var isStarted = false

    init() {}

    func bestMove(for position: Position, settings: AISettings) async throws -> Move {
        try await ensureStarted()

        let skill = max(0, min(20, settings.skillLevel))
        let movetimeMs = milliseconds(of: settings.thinkingTime)

        await engine.send(command: .setoption(id: "Skill Level", value: "\(skill)"))
        await engine.send(command: .position(.fen(position.fen)))
        await engine.send(command: .go(movetime: movetimeMs))

        // Hard cap: the engine should reply with `bestmove` shortly after
        // `movetime` elapses. Anything beyond that is a stuck process —
        // bail out, send `stop` defensively, and surface a clear error to
        // the caller instead of hanging the UI. The 20 s safety pad is
        // generous because Stockfish startup + NNUE load can take a
        // couple of seconds on the first request, and CI runs may share
        // CPU with other tests / Lichess model tests in the same
        // process. Real-game thinking times are way under this margin.
        let budget: Duration = .milliseconds(movetimeMs) + .seconds(20)
        return try await withCancellationStop {
            try await waitForBestMove(within: budget)
        }
    }

    func stop() async {
        guard isStarted else { return }
        await engine.stop()
        isStarted = false
    }

    // MARK: - Private

    private func ensureStarted() async throws {
        if isStarted { return }

        // chesskit-engine's default thread heuristic clamps to 1; pass an
        // explicit core count so Stockfish actually parallelises search on
        // the M-class CPUs that Vision Pro and the simulator host use.
        // Leave at least 2 cores for the system and cap at 5 (== 4 search
        // threads after chesskit-engine's `coreCount - 1` adjustment) so
        // we don't starve UI work while the engine thinks.
        let available = ProcessInfo.processInfo.activeProcessorCount
        let coreCount = max(2, min(5, available - 2))

        await engine.start(coreCount: coreCount)

        // The engine flips `isRunning` to `true` only after the
        // uci → uciok → isready → readyok handshake AND the initial
        // setoption batch (Threads, MultiPV, EvalFile, EvalFileSmall).
        // 200 × 50 ms = 10 s ceiling so a stuck handshake fails loudly.
        for _ in 0..<200 {
            if await engine.isRunning {
                isStarted = true
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AIError.engineUnavailable
    }

    /// Iterates the engine's response stream until a `bestmove` arrives or the
    /// budget elapses. `info` / `id` / `uciok` / `readyok` are skipped — only
    /// `bestmove` terminates the wait.
    private func waitForBestMove(within budget: Duration) async throws -> Move {
        guard let stream = await engine.responseStream else {
            throw AIError.engineUnavailable
        }

        return try await withThrowingTaskGroup(of: Move.self) { group in
            group.addTask {
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
            group.addTask {
                try await Task.sleep(for: budget)
                throw AIError.timedOut
            }

            // Whichever finishes first wins; cancel the loser so it doesn't
            // keep iterating the stream / sleeping in the background.
            let winner = try await group.next()!
            group.cancelAll()
            return winner
        }
    }

    /// Wraps a body that waits on the engine. If the calling task is
    /// cancelled mid-search, asks Stockfish to stop and lets the body settle
    /// (it will receive the resulting `bestmove`, return normally, and the
    /// outer caller will see `Task.isCancelled` and discard the result —
    /// `MatchCoordinator` already does this). Sending `stop` is critical:
    /// without it Stockfish keeps thinking on the cancelled position and the
    /// next request would receive a stale `bestmove`.
    private func withCancellationStop<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await body()
        } onCancel: { [engine] in
            Task { await engine.send(command: .stop) }
        }
    }

    private func milliseconds(of duration: Duration) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return max(50, Int((seconds * 1000).rounded()))
    }
}
