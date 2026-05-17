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
    case excellent     // CP loss < 30
    case good          // CP loss 30..<100
    case inaccuracy    // CP loss 100..<200
    case mistake       // CP loss 200..<500
    case blunder       // CP loss >= 500

    var displayName: String {
        switch self {
        case .best:       return "Best"
        case .great:      return "Great"
        case .excellent:  return "Excellent"
        case .good:       return "Good"
        case .inaccuracy: return "Inaccuracy"
        case .mistake:    return "Mistake"
        case .blunder:    return "Blunder"
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

    /// Per-Lichess-style accuracy: 100 - mean(CPL clamped to 1000) / 10.
    /// A rough approximation — not the official Lichess formula but
    /// produces a comparable 0–100 scale.
    func accuracy(for side: Side) -> Double {
        let losses = moves.filter { $0.mover == side }.map { Double($0.centipawnLoss) }
        guard !losses.isEmpty else { return 100 }
        let mean = losses.reduce(0, +) / Double(losses.count)
        let raw = 100.0 - (mean / 10.0)
        return max(0, min(100, raw))
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
                        let quality = Self.classify(
                            cpLoss: cpLoss,
                            played: playedUCI,
                            best: bestLine?.uci,
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

    /// CP-loss based classification with an only-move boost to `great`.
    nonisolated static func classify(
        cpLoss: Int, played: String, best: String?, lines: [AnalysisLine]
    ) -> MoveQuality {
        let isBest = (played == best)

        // "Great" = the move played was the best AND the alternative
        // was significantly worse (200cp gap between top1 and top2).
        // Catches only-good-move tactical finds without the full
        // sacrifice-detection of "brilliant".
        if isBest, lines.count >= 2 {
            let gap = lines[0].scoreCp - lines[1].scoreCp
            if gap >= 200 { return .great }
        }
        if isBest { return .best }
        switch cpLoss {
        case ..<30:   return .excellent
        case ..<100:  return .good
        case ..<200:  return .inaccuracy
        case ..<500:  return .mistake
        default:      return .blunder
        }
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
