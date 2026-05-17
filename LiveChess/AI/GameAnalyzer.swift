import Foundation
import ChessKitEngine

/// Per-move review analysis emitted by `GameAnalyzer`.
///
/// One `MoveAnalysis` per ply in the reviewed game. `playedScoreCp`
/// and `bestScoreCp` are always from the perspective of the side that
/// moved (positive = good for them). `centipawnLoss` is the magnitude
/// of the player's mistake — `bestScoreCp - playedScoreCp`, clamped to
/// `[0, 1000]`. The classification thresholds on `MoveQuality` operate
/// on this value.
struct MoveAnalysis: Identifiable, Sendable, Hashable {
    let id: Int                        // ply index (0-based)
    let san: String                    // SAN of the move played (or UCI if SAN unavailable)
    let playedUCI: String
    let mover: Side                    // who played this move
    let playedScoreCp: Int             // eval after the player's move, in mover's POV
    let bestScoreCp: Int               // eval of the best move at this position, mover's POV
    let centipawnLoss: Int             // max(0, bestScoreCp - playedScoreCp), clamp 1000
    /// Δwin% between the best and played move (0…100). This is what
    /// drives the quality classification — raw cp loss over-flags
    /// moves in already-decisive positions and under-flags moves
    /// near 0.0, the win% sigmoid corrects for that.
    let winPercentLoss: Double
    let topLines: [AnalysisLine]       // up to MultiPV candidate moves at the prior position
    let quality: MoveQuality
}

/// One candidate move with its evaluation and a short PV.
struct AnalysisLine: Sendable, Hashable {
    let uci: String                    // first move of the line
    let scoreCp: Int                   // eval, mover's POV
    let mate: Int?                     // mate-in-N if any
    let pv: [String]                   // UCI moves (first move == `uci`)
}

/// Classification buckets, in roughly the order chess.com / Lichess use.
///
/// The user-visible label, glyph and accent colour drive the UI. The
/// classification is computed from `MoveAnalysis.centipawnLoss` plus a
/// "only-good-move" check against the second-best candidate (`great`).
/// `brilliant` would also need material-sacrifice detection so we
/// leave it out of v1 to avoid false positives.
enum MoveQuality: String, Sendable, Hashable, CaseIterable, Codable {
    case best          // engine's top pick
    case great         // best when alternatives are clearly worse (only-move)
    case excellent     // Δwin% < 2
    case good          // Δwin% 2..<5
    case inaccuracy    // Δwin% 5..<10
    case mistake       // Δwin% 10..<20
    case blunder       // Δwin% >= 20
    case missedWin     // had ≥+200cp advantage, played a move that drops to ~0 or worse

    var displayName: String {
        switch self {
        case .best:       return "Best"
        case .great:      return "Great"
        case .excellent:  return "Excellent"
        case .good:       return "Good"
        case .inaccuracy: return "Inaccuracy"
        case .mistake:    return "Mistake"
        case .blunder:    return "Blunder"
        case .missedWin:  return "Missed Win"
        }
    }

    /// Compact glyph for inline display next to the move text.
    var glyph: String {
        switch self {
        case .best:       return "★"
        case .great:      return "!"
        case .excellent:  return "✓"
        case .good:       return "✓"
        case .inaccuracy: return "?!"
        case .mistake:    return "?"
        case .blunder:    return "??"
        case .missedWin:  return "✕"
        }
    }
}

/// Aggregated review of a full game, with per-side counters used by
/// the summary card at the top of `GameReviewDetailView`.
struct GameAnalysisResult: Sendable {
    let moves: [MoveAnalysis]

    func count(_ q: MoveQuality, for side: Side) -> Int {
        moves.filter { $0.mover == side && $0.quality == q }.count
    }

    /// Accuracy in chess.com's win%-loss family: `100 - mean(Δwin%)`.
    /// Same scale as their displayed accuracy (0–100, higher better).
    /// A pure-best player scores 100; consistent blunders pull it
    /// down to the 60s. Lichess uses a different sigmoid weighting
    /// but the order-of-magnitude matches.
    func accuracy(for side: Side) -> Double {
        let losses = moves.filter { $0.mover == side }.map(\.winPercentLoss)
        guard !losses.isEmpty else { return 100 }
        let mean = losses.reduce(0, +) / Double(losses.count)
        return max(0, min(100, 100.0 - mean))
    }
}

/// Drives Stockfish through a game's move list to produce per-move
/// classifications and PV lines.
///
/// One `GameAnalyzer` owns one `Engine`, started with `multipv: 3`
/// (configurable). Calling `analyze` runs the engine ply by ply at a
/// fixed search depth; results stream out via the
/// `AsyncStream<MoveAnalysis>` returned by `analyzeStream`. The total
/// review of a 40-move game at depth 16 lands around 30–60 s on M-class
/// silicon — fast enough to keep the UI responsive, slow enough that
/// we always emit progressively rather than blocking on a one-shot
/// `analyze` returning the full result.
actor GameAnalyzer {

    private let multiPV: Int
    private let engine: Engine
    private var isStarted = false

    init(multiPV: Int = 3) {
        self.multiPV = multiPV
        self.engine = Engine(type: .stockfish)
    }

    /// Streams `MoveAnalysis` records ply by ply. Caller iterates and
    /// updates the UI as each ply lands; the stream completes when
    /// every ply has been analyzed or the task is cancelled.
    func analyzeStream(
        startPosition: Position = .standardStart,
        moves: [Move],
        depth: Int = 16,
        rules: any RulesEngine = ChessKitRulesEngine()
    ) -> AsyncThrowingStream<MoveAnalysis, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await ensureStarted()
                    var position = startPosition
                    for (ply, move) in moves.enumerated() {
                        try Task.checkCancellation()
                        // Evaluate the position BEFORE the move with
                        // MultiPV=N — gives us the top-N candidates +
                        // their scores, all from `position.sideToMove`'s
                        // POV at depth `depth`.
                        let mover = position.sideToMove
                        let lines = try await evaluate(
                            fen: position.fen, depth: depth
                        )

                        // Did the player pick one of the top candidates?
                        let playedUCI = move.uci
                        let bestLine = lines.first
                        let bestScore = bestLine?.scoreCp ?? 0

                        let playedScore: Int
                        if let match = lines.first(where: { $0.uci == playedUCI }) {
                            playedScore = match.scoreCp
                        } else {
                            // Off-top-N: eval position AFTER the move
                            // and negate (opponent's POV → mover's).
                            let nextFen = try? rules.apply(move, to: position).fen
                            if let nextFen {
                                let oppLines = try await evaluate(
                                    fen: nextFen, depth: depth
                                )
                                playedScore = -(oppLines.first?.scoreCp ?? 0)
                            } else {
                                playedScore = bestScore
                            }
                        }

                        let cpLoss = max(0, min(1000, bestScore - playedScore))
                        let winLoss = max(
                            0.0,
                            Self.winPercent(fromCp: bestScore)
                              - Self.winPercent(fromCp: playedScore)
                        )
                        let quality = Self.classify(
                            played: playedUCI,
                            best: bestLine?.uci,
                            bestScoreCp: bestScore,
                            playedScoreCp: playedScore,
                            winPercentLoss: winLoss,
                            lines: lines
                        )

                        let analysis = MoveAnalysis(
                            id: ply,
                            san: move.uci,
                            playedUCI: playedUCI,
                            mover: mover,
                            playedScoreCp: playedScore,
                            bestScoreCp: bestScore,
                            centipawnLoss: cpLoss,
                            winPercentLoss: winLoss,
                            topLines: lines,
                            quality: quality
                        )
                        continuation.yield(analysis)

                        // Advance through the actual move played.
                        position = try rules.apply(move, to: position)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let engineRef = self.engine
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await engineRef.send(command: .stop)
                }
            }
        }
    }

    /// One-shot convenience that collects the stream into a single
    /// result. Prefer `analyzeStream` for UI so each move appears as
    /// soon as it's analyzed.
    func analyze(
        startPosition: Position = .standardStart,
        moves: [Move],
        depth: Int = 16,
        rules: any RulesEngine = ChessKitRulesEngine()
    ) async throws -> GameAnalysisResult {
        var collected: [MoveAnalysis] = []
        for try await m in analyzeStream(
            startPosition: startPosition, moves: moves,
            depth: depth, rules: rules
        ) {
            collected.append(m)
        }
        return GameAnalysisResult(moves: collected)
    }

    func shutdown() async {
        guard isStarted else { return }
        await engine.stop()
        isStarted = false
    }

    // MARK: - Engine I/O

    private func ensureStarted() async throws {
        if isStarted { return }
        let available = ProcessInfo.processInfo.activeProcessorCount
        // Leave more headroom for the UI than the play-engine does —
        // game review is a background task, not a turn-time deadline.
        let coreCount = max(2, min(4, available - 3))
        await engine.start(coreCount: coreCount, multipv: multiPV)
        // Strength-cap NOT applied here: review wants the full
        // engine strength to evaluate moves correctly.
        for _ in 0..<200 {
            if await engine.isRunning {
                isStarted = true
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AIError.engineUnavailable
    }

    /// Sends `position fen … / go depth N` and consumes the response
    /// stream until `bestmove` arrives. Returns the latest set of
    /// `info` lines (one per MultiPV slot) at the final depth, parsed
    /// into `AnalysisLine`s with mover-POV scores.
    private func evaluate(
        fen: String, depth: Int
    ) async throws -> [AnalysisLine] {
        await engine.send(command: .position(.fen(fen)))
        await engine.send(command: .go(depth: depth))

        guard let stream = await engine.responseStream else {
            throw AIError.engineUnavailable
        }

        // Per-MultiPV slot, keep the deepest info we've seen. When
        // Stockfish iteratively deepens it emits info at depth 1, 2,
        // 3, … for each slot; we overwrite on every new info because
        // later depths are strictly better.
        var latest: [Int: AnalysisLine] = [:]

        for await response in stream {
            switch response {
            case .info(let info):
                guard let pv = info.pv, !pv.isEmpty,
                      let slot = info.multipv ?? 1 as Int? else { continue }
                let score = info.score
                let cp = score?.cp.map { Int($0.rounded()) } ?? 0
                let mate = score?.mate
                let line = AnalysisLine(
                    uci: pv[0],
                    scoreCp: mate.map { Self.mateToCp($0) } ?? cp,
                    mate: mate,
                    pv: pv
                )
                latest[slot] = line
            case .bestmove:
                return latest.keys.sorted().compactMap { latest[$0] }
            default:
                continue
            }
        }
        throw AIError.noMoveProduced
    }

    // MARK: - Classification

    /// Win%-loss based classification matching chess.com's family of
    /// buckets. Uses `winPercent(fromCp:)` to map eval to expected
    /// score so a 200cp swing at +15 (still totally winning) doesn't
    /// flag as a "mistake", and a 50cp swing from 0.0 to -0.5 (now
    /// clearly worse) doesn't get under-counted.
    ///
    /// Priority order:
    ///   * `missedWin` — was ≥+200cp ahead, played a move that drops
    ///     to ≤+50cp. Beats `mistake`/`blunder` because losing a win
    ///     is qualitatively different from a positional slip.
    ///   * `great` — top engine pick AND second-best is ≥10 win%
    ///     worse (only-good-move tactical find).
    ///   * `best` — matches engine's top pick.
    ///   * Δwin% buckets: <2 excellent / <5 good / <10 inaccuracy /
    ///     <20 mistake / ≥20 blunder.
    nonisolated static func classify(
        played: String,
        best: String?,
        bestScoreCp: Int,
        playedScoreCp: Int,
        winPercentLoss: Double,
        lines: [AnalysisLine]
    ) -> MoveQuality {
        // Missed-win check first — if the player threw away a clearly
        // winning advantage, the move quality is dominated by that
        // fact regardless of how badly the cp number swung.
        if bestScoreCp >= 200, playedScoreCp <= 50 {
            return .missedWin
        }

        let isBest = (played == best)
        if isBest, lines.count >= 2 {
            let topWin = winPercent(fromCp: lines[0].scoreCp)
            let secondWin = winPercent(fromCp: lines[1].scoreCp)
            if (topWin - secondWin) >= 10 { return .great }
        }
        if isBest { return .best }

        switch winPercentLoss {
        case ..<2:    return .excellent
        case ..<5:    return .good
        case ..<10:   return .inaccuracy
        case ..<20:   return .mistake
        default:      return .blunder
        }
    }

    /// Maps a centipawn score to expected win percentage [0…100] via
    /// `50 + 50·tanh(cp/400)`. Tanh saturates near ±100 so deep
    /// advantages (already winning / already losing) don't punish
    /// further cp swings — matches chess.com's behaviour where Δwin%
    /// drives the classification, not raw cp loss.
    ///
    /// Mate scores get clamped to ±99.95% via the large cp values
    /// returned by `mateToCp` (sigmoid saturates well before 10 000).
    nonisolated static func winPercent(fromCp cp: Int) -> Double {
        let pawns = Double(cp) / 400.0
        return 50.0 + 50.0 * tanh(pawns)
    }

    /// Map mate-in-N to a large centipawn so comparisons against
    /// regular cp scores work without special-casing. Sign preserved.
    /// Closer mates score higher (mate-in-1 > mate-in-10).
    nonisolated static func mateToCp(_ mate: Int) -> Int {
        let sign = mate >= 0 ? 1 : -1
        let distance = abs(mate)
        return sign * (10_000 - distance)
    }
}
