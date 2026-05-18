import Foundation
import Observation

/// `MatchSession` implementation that drives the immersive 3-D board
/// through a pre-recorded game for review. Pieces animate as the user
/// steps through the move list using the HUD's `|<  <  ▶  >  >|`
/// controls. Gestures on the board are disabled — review is HUD-only.
///
/// Analysis (per-move classification + top engine lines) is supplied
/// asynchronously by `GameAnalyzer` and surfaced to the HUD via the
/// `analysisProgress` / `analysisResults` observable arrays. Stepping
/// through the game does NOT block on analysis — the user can scrub
/// ahead while Stockfish catches up; classifications materialise as
/// they arrive.
@MainActor
@Observable
final class ReviewSession: MatchSession {

    /// Title shown in the HUD header.
    let titleLine: String
    let subtitleLine: String
    /// The result string ("1 – 0" / "½ – ½" / etc.) for the matchup
    /// header.
    let resultLine: String

    /// Full move sequence, pre-validated against the rules engine.
    let plyMoves: [Move]
    /// Position after each ply. `positionsByPly[0]` is the start
    /// (before any move), `positionsByPly[k+1]` is after `plyMoves[k]`.
    let positionsByPly: [Position]

    /// `-1` = starting position (no move applied yet).
    /// `0…plyMoves.count - 1` = position AFTER move `currentPly`.
    private(set) var currentPly: Int = -1

    /// Per-ply analysis as it streams in from `GameAnalyzer`. Indexed
    /// by ply (0-based). May be shorter than `plyMoves` while analysis
    /// is still running; HUD checks `analysisResults.indices`.
    private(set) var analysisResults: [MoveAnalysis] = []
    private(set) var isAnalyzing: Bool = false

    /// True when auto-play is stepping forward on a timer.
    private(set) var isAutoPlaying: Bool = false

    /// Underlying `Match` re-built every time the user navigates so
    /// `ChessSceneView` can re-seed pieces. We replay through the
    /// rules engine on each navigation rather than mutating the
    /// stored `Match` step by step — keeps the data model simple.
    private(set) var match: Match

    private let rules: any RulesEngine
    private var analyzer: GameAnalyzer?
    private var analysisTask: Task<Void, Never>?
    private var autoPlayTask: Task<Void, Never>?

    var moveAppliedHandler: (@MainActor (Move) -> Void)?
    var matchResetHandler: (@MainActor () -> Void)?

    init?(game: LichessGame,
          username: String,
          rules: any RulesEngine = ChessKitRulesEngine()) {
        // Lichess returns the `moves` field as space-separated SAN
        // ("e4 e5 Nf3 Nc6 …"), not UCI — `Move(uci:)` would never
        // parse a single token. Route through SANConverter which
        // also handles UCI as a fast-path so the analyzer tests
        // keep working.
        let parsed = SANConverter.parse(game.moves ?? "")
        guard !parsed.isEmpty else { return nil }

        var positions: [Position] = [.standardStart]
        for m in parsed {
            do {
                positions.append(try rules.apply(m, to: positions.last!))
            } catch {
                positions.append(positions.last!)
            }
        }
        self.plyMoves = parsed
        self.positionsByPly = positions
        self.rules = rules
        self.match = Match(startPosition: .standardStart)

        let opp = game.opponent(for: username)
        let myAcc = game.accuracy(for: username).map { String(format: "%.0f%%", $0) }
        self.titleLine = "Review · vs \(opp)"
        if let acc = myAcc {
            self.subtitleLine = "Your accuracy \(acc) · \(parsed.count) plies"
        } else {
            self.subtitleLine = "\(parsed.count) plies"
        }
        switch game.winner {
        case "white": self.resultLine = "1 – 0"
        case "black": self.resultLine = "0 – 1"
        default:      self.resultLine = "½ – ½"
        }

        // Lichess already analyzed this game on their servers — every
        // entry in `Analyzed Games` carries an `analysis` array. Seed
        // the HUD directly from Lichess so classifications appear the
        // instant the immersive board opens, instead of waiting for
        // local Stockfish to chew through 40 plies at depth 20.
        if let cloudEvals = game.analysis, !cloudEvals.isEmpty {
            self.analysisResults = Self.buildAnalysis(
                from: cloudEvals,
                plyMoves: parsed,
                positionsByPly: positions
            )
        }
    }

    // MARK: - MatchSession

    var isHumanTurn: Bool { false }
    func legalMoves(from square: Square) -> [Move] { [] }
    func submitMove(_ move: Move) async { /* read-only */ }

    // MARK: - Navigation

    func stepForward() {
        stopAutoPlay()
        advance(by: 1)
    }
    func stepBack() {
        stopAutoPlay()
        advance(by: -1)
    }
    func goToStart() {
        stopAutoPlay()
        jumpTo(ply: -1)
    }
    func goToEnd() {
        stopAutoPlay()
        jumpTo(ply: plyMoves.count - 1)
    }
    func jumpTo(ply: Int) {
        let clamped = max(-1, min(plyMoves.count - 1, ply))
        guard clamped != currentPly else { return }
        currentPly = clamped
        rebuildMatchAndAnnounce()
    }

    func toggleAutoPlay() {
        if isAutoPlaying { stopAutoPlay() } else { startAutoPlay() }
    }

    private func advance(by delta: Int) {
        let next = currentPly + delta
        guard next >= -1, next < plyMoves.count else { return }
        if delta == 1, next >= 0, next < plyMoves.count {
            // Forward step — animate the single move.
            currentPly = next
            let move = plyMoves[next]
            let newPos = positionsByPly[next + 1]
            let newStatus = rules.status(of: newPos, history: positionsByPly)
            match.apply(move: move, resulting: newPos, status: newStatus)
            moveAppliedHandler?(move)
        } else {
            // Backward step or other discontinuity — replay from start.
            currentPly = next
            rebuildMatchAndAnnounce()
        }
    }

    /// Reset `match` to the position at `currentPly` and tell the
    /// renderer to re-seed.
    private func rebuildMatchAndAnnounce() {
        let idx = currentPly + 1
        let pos = (idx >= 0 && idx < positionsByPly.count)
            ? positionsByPly[idx] : .standardStart
        match.reset(to: pos, status: rules.status(of: pos, history: [pos]))
        matchResetHandler?()
    }

    // MARK: - Auto-play

    private func startAutoPlay() {
        guard !isAutoPlaying else { return }
        isAutoPlaying = true
        autoPlayTask = Task { @MainActor [weak self] in
            while let self, self.isAutoPlaying,
                  self.currentPly + 1 < self.plyMoves.count {
                try? await Task.sleep(for: .milliseconds(900))
                if Task.isCancelled || !self.isAutoPlaying { break }
                self.advance(by: 1)
            }
            self?.isAutoPlaying = false
        }
    }

    private func stopAutoPlay() {
        isAutoPlaying = false
        autoPlayTask?.cancel()
        autoPlayTask = nil
    }

    // MARK: - Analysis (kicked off by the HUD on first appearance)

    func startAnalysisIfNeeded() {
        // Lichess cloud already populated `analysisResults` in init — no
        // need to spin up local Stockfish at all. Saves the user ~90 s
        // per game on a typical 40-move review.
        guard analysisResults.isEmpty else { return }
        guard analyzer == nil, !plyMoves.isEmpty else { return }
        let analyzer = GameAnalyzer(multiPV: 3)
        self.analyzer = analyzer
        isAnalyzing = true
        analysisTask = Task { @MainActor in
            do {
                let stream = await analyzer.analyzeStream(
                    startPosition: .standardStart,
                    moves: plyMoves,
                    depth: 20
                )
                for try await m in stream {
                    if Task.isCancelled { break }
                    self.analysisResults.append(m)
                }
            } catch {
                // Non-fatal — analysis just stops; navigation still works.
            }
            self.isAnalyzing = false
            await analyzer.shutdown()
        }
    }

    func tearDown() {
        stopAutoPlay()
        analysisTask?.cancel()
        analysisTask = nil
        let a = analyzer
        Task { await a?.shutdown() }
    }

    // MARK: - Derived UI helpers

    var currentMove: Move? {
        guard currentPly >= 0, currentPly < plyMoves.count else { return nil }
        return plyMoves[currentPly]
    }

    /// Engine's preferred move at the position BEFORE the current ply.
    var bestMoveAtCurrent: Move? {
        guard currentPly >= 0, currentPly < analysisResults.count,
              let uci = analysisResults[currentPly].topLines.first?.uci
        else { return nil }
        return Move(uci: uci)
    }

    var currentClassification: MoveAnalysis? {
        guard currentPly >= 0, currentPly < analysisResults.count else { return nil }
        return analysisResults[currentPly]
    }

    var plyLabel: String {
        "\(currentPly + 1) / \(plyMoves.count)"
    }

    var canStepBack: Bool { currentPly >= 0 }
    var canStepForward: Bool { currentPly + 1 < plyMoves.count }

    // MARK: - Lichess-cloud → MoveAnalysis

    /// Maps Lichess's per-ply analysis array into our `MoveAnalysis`
    /// shape so the HUD can render badges and engine lines without
    /// re-running Stockfish. Lichess evals are in centipawns from
    /// **white's** point of view; we re-orient to the mover's POV so
    /// the existing classifier behaves identically to the local one.
    ///
    /// `judgment.name` on Lichess uses three labels — "Inaccuracy",
    /// "Mistake", "Blunder". Moves without a judgment but where played
    /// == best get `.best`; everything else gets the win-% bucket
    /// (`.excellent` / `.good`) the local analyzer would have picked.
    nonisolated static func buildAnalysis(
        from cloud: [LichessMoveEval],
        plyMoves: [Move],
        positionsByPly: [Position]
    ) -> [MoveAnalysis] {
        var out: [MoveAnalysis] = []
        out.reserveCapacity(min(cloud.count, plyMoves.count))

        // White's POV eval before any move. `0` matches the convention
        // every UCI engine uses for the start position.
        var prevEvalWhitePOV = 0

        for (ply, entry) in cloud.enumerated() where ply < plyMoves.count {
            let mover: Side = (ply % 2 == 0) ? .white : .black

            // Convert Lichess's white-POV eval into mover-POV scores.
            // For `mate`, fold into a large signed cp so the existing
            // win-% sigmoid saturates correctly without a special path.
            let evalAfterWhite: Int
            if let mate = entry.mate {
                evalAfterWhite = GameAnalyzer.mateToCp(mate)
            } else {
                evalAfterWhite = entry.eval ?? prevEvalWhitePOV
            }
            let evalBeforeMover = (mover == .white) ?  prevEvalWhitePOV : -prevEvalWhitePOV
            let evalAfterMover  = (mover == .white) ?  evalAfterWhite   : -evalAfterWhite

            // Material delta — how much material the mover gave up on
            // this move. Computed purely from the position pair, no
            // engine needed. Drives `Brilliant` detection.
            let positionBefore = positionsByPly[ply]
            let positionAfter = (ply + 1 < positionsByPly.count)
                ? positionsByPly[ply + 1] : positionBefore
            let materialDelta = GameAnalyzer.materialBalance(
                for: mover, in: positionAfter
            ) - GameAnalyzer.materialBalance(for: mover, in: positionBefore)

            // Lichess doesn't tell us "what eval would the best move
            // have produced". The standard assumption — also what
            // Lichess uses internally — is that the best move would
            // have maintained the eval as it was BEFORE the move
            // (mover's POV). Anything worse than that is the player's
            // loss for this ply.
            let bestScoreCp = evalBeforeMover
            let playedScoreCp = evalAfterMover
            let cpLoss = max(0, min(1000, bestScoreCp - playedScoreCp))
            let winLoss = max(
                0.0,
                GameAnalyzer.winPercent(fromCp: bestScoreCp)
                  - GameAnalyzer.winPercent(fromCp: playedScoreCp)
            )

            // Build a single-line `topLines` from Lichess's best/
            // variation pair so the HUD's engine-line card has
            // something to show. PV is in SAN on Lichess; the HUD
            // already renders SAN tokens directly.
            var topLines: [AnalysisLine] = []
            if let best = entry.best {
                let pv = entry.variation?
                    .split(separator: " ")
                    .map(String.init) ?? [best]
                topLines.append(AnalysisLine(
                    uci: best,
                    scoreCp: bestScoreCp,
                    mate: (mover == .white) ? entry.mate : entry.mate.map { -$0 },
                    pv: pv
                ))
            }

            let quality = qualityFromLichess(
                entry: entry,
                playedUCI: plyMoves[ply].uci,
                winPercentLoss: winLoss,
                bestScoreCp: bestScoreCp,
                playedScoreCp: playedScoreCp,
                materialDelta: materialDelta
            )

            out.append(MoveAnalysis(
                id: ply,
                san: plyMoves[ply].uci,
                playedUCI: plyMoves[ply].uci,
                mover: mover,
                playedScoreCp: playedScoreCp,
                bestScoreCp: bestScoreCp,
                centipawnLoss: cpLoss,
                winPercentLoss: winLoss,
                topLines: topLines,
                quality: quality,
                bookOpening: nil
            ))

            prevEvalWhitePOV = evalAfterWhite
        }
        return out
    }

    /// Map a Lichess judgment to our `MoveQuality`. When the entry
    /// carries no judgment Lichess considers the move "in book" —
    /// either an opening line or simply unannotated. We pick the
    /// closest bucket from the win-% loss so the HUD still shows a
    /// classification (best / excellent / good) instead of leaving
    /// those moves blank.
    nonisolated static func qualityFromLichess(
        entry: LichessMoveEval,
        playedUCI: String,
        winPercentLoss: Double,
        bestScoreCp: Int,
        playedScoreCp: Int,
        materialDelta: Int
    ) -> MoveQuality {
        if bestScoreCp >= 200, playedScoreCp <= 50 {
            return .missedWin
        }

        let isBest = entry.best.map { $0 == playedUCI } ?? false

        // BRILLIANT (‼) — Lichess flagged this as the engine's pick AND
        // the player gave up ≥3 pts of material (minor piece or more)
        // AND the resulting eval (mover POV) is still winning. Lichess
        // doesn't return MultiPV, so we can't filter forced recaptures
        // the way the local analyzer does — false positives are rare
        // because Lichess's `best` already requires the engine to
        // pick that move at depth, not just allow it.
        if isBest, materialDelta <= -3, playedScoreCp >= 0 {
            return .brilliant
        }

        if let name = entry.judgment?.name {
            switch name {
            case "Inaccuracy": return .inaccuracy
            case "Mistake":    return .mistake
            case "Blunder":    return .blunder
            default:           break
            }
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
}
