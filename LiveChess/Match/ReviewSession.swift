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
    /// Lichess game ID — used to deep-link back to the game on
    /// lichess.org so the user can request a deep computer analysis
    /// when Lichess hasn't already produced one.
    let gameId: String

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

    /// Stack of moves the user has played as a side variation off the
    /// main game line. Empty = displaying main line at `currentPly`.
    /// Non-empty = the board is at the variation's tip; main-line
    /// navigation (chevrons / scrub) clears the variation first.
    private(set) var variation: [VariationStep] = []

    /// Per-variation-move analysis from local Stockfish. Indexed
    /// 1-to-1 with `variation`. Mirrors `analysisResults` semantically
    /// — the HUD reads from this when `variation.isNotEmpty`.
    private(set) var variationAnalysis: [MoveAnalysis] = []

    /// One pushed move on the user-explored variation.
    struct VariationStep: Sendable {
        let move: Move
        let positionBefore: Position
        let positionAfter: Position
        let status: GameStatus
    }

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

    /// Fires whenever the displayed move (main-line ply OR variation
    /// tip) changes. Carries the move's source + destination squares
    /// and the classification of that move so the renderer can drop a
    /// quality-coloured overlay on the board.
    var reviewHighlightHandler: (@MainActor (Square?, Square?, MoveQuality?) -> Void)?

    /// Fires alongside the highlight whenever the displayed move
    /// wasn't the engine's top pick — carries the engine's preferred
    /// move's source + destination so the renderer can draw a 3D
    /// arrow showing the recommended alternative. `(nil, nil)` means
    /// hide the arrow (played == best, no analysis yet, etc.).
    var bestMoveArrowHandler: (@MainActor (Square?, Square?) -> Void)?

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
        self.gameId = game.id

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
            print("[Review] Loaded \(cloudEvals.count) plies from Lichess cloud analysis (instant).")
        } else {
            print("[Review] No cloud analysis for game \(game.id) — local Stockfish will analyze \(parsed.count) plies at depth 14.")
        }
    }

    // MARK: - MatchSession

    /// Always true during review — we want the user to be able to grab
    /// any piece from any reached position and play an alternative
    /// move. `submitMove` decides whether it lands in the main line
    /// or pushes onto the variation stack.
    var isHumanTurn: Bool { true }

    /// Legal moves at the *displayed* position. When the user is in a
    /// variation, this is the variation tip; otherwise it's the main
    /// line's position at `currentPly + 1`.
    func legalMoves(from square: Square) -> [Move] {
        rules.legalMoves(from: square, in: displayedPosition)
    }

    /// Apply an alternative move on top of the current display. Always
    /// pushes onto the variation stack — main-line moves replay via
    /// the chevrons / scrub, never by drag.
    func submitMove(_ move: Move) async {
        stopAutoPlay()
        let from = displayedPosition
        guard let after = try? rules.apply(move, to: from) else { return }
        let history = positionsByPly + variation.map(\.positionAfter) + [after]
        let status = rules.status(of: after, history: history)
        let step = VariationStep(
            move: move,
            positionBefore: from,
            positionAfter: after,
            status: status
        )
        variation.append(step)
        match.apply(move: move, resulting: after, status: status)
        moveAppliedHandler?(move)
        emitReviewHighlight()
        let index = variation.count - 1
        Task {
            await analyzeVariationStep(at: index)
            // Re-emit so the overlay colour upgrades from the placeholder
            // `.good` to whatever Stockfish actually picked.
            emitReviewHighlight()
        }
    }

    /// Drop the variation stack and re-seed the board to the main-line
    /// position at `currentPly`. Called from the HUD's "Back to game"
    /// button and implicitly when the user uses any main-line nav.
    func clearVariation() {
        guard !variation.isEmpty else { return }
        variation.removeAll()
        variationAnalysis.removeAll()
        rebuildMatchAndAnnounce()
    }

    /// True iff the user has branched off the main line.
    var isInVariation: Bool { !variation.isEmpty }

    /// Position the renderer is showing — main-line tip or variation tip.
    var displayedPosition: Position {
        if let last = variation.last { return last.positionAfter }
        let idx = currentPly + 1
        return (idx >= 0 && idx < positionsByPly.count)
            ? positionsByPly[idx] : .standardStart
    }

    // MARK: - Navigation

    func stepForward() {
        stopAutoPlay()
        if isInVariation { clearVariation(); return }
        advance(by: 1)
    }
    func stepBack() {
        stopAutoPlay()
        if isInVariation { clearVariation(); return }
        advance(by: -1)
    }
    func goToStart() {
        stopAutoPlay()
        if isInVariation { variation.removeAll(); variationAnalysis.removeAll() }
        jumpTo(ply: -1)
    }
    func goToEnd() {
        stopAutoPlay()
        if isInVariation { variation.removeAll(); variationAnalysis.removeAll() }
        jumpTo(ply: plyMoves.count - 1)
    }
    func jumpTo(ply: Int) {
        if isInVariation { variation.removeAll(); variationAnalysis.removeAll() }
        let clamped = max(-1, min(plyMoves.count - 1, ply))
        guard clamped != currentPly else {
            // Same ply requested — still need to rebuild the board if
            // the variation cleared above changed the displayed state.
            rebuildMatchAndAnnounce()
            return
        }
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
            emitReviewHighlight()
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
        emitReviewHighlight()
    }

    /// Compute the (from, to, quality) triple for the move that's
    /// currently shown on the board — variation tip wins over the
    /// main-line ply at `currentPly` — and push it to the renderer
    /// via `reviewHighlightHandler`. Safe to call when nothing is
    /// being displayed: emits a `(nil, nil, nil)` payload that the
    /// renderer interprets as "clear".
    func emitReviewHighlight() {
        // Compute the displayed move + its analysis once and dispatch
        // to both handlers. Highlight always fires; arrow only when
        // the played move ≠ engine's pick AND we have a best move.
        let (move, quality, bestUCI): (Move?, MoveQuality?, String?) = {
            if let lastStep = variation.last {
                let idx = variation.count - 1
                let a = (idx < variationAnalysis.count) ? variationAnalysis[idx] : nil
                return (lastStep.move, a?.quality, a?.topLines.first?.uci)
            }
            guard currentPly >= 0, currentPly < plyMoves.count else {
                return (nil, nil, nil)
            }
            let m = plyMoves[currentPly]
            let a = (currentPly < analysisResults.count) ? analysisResults[currentPly] : nil
            return (m, a?.quality, a?.topLines.first?.uci)
        }()

        reviewHighlightHandler?(move?.from, move?.to, quality)

        if let handler = bestMoveArrowHandler {
            if let move, let bestUCI,
               bestUCI != move.uci,
               let best = Move(uci: bestUCI) {
                handler(best.from, best.to)
            } else {
                handler(nil, nil)
            }
        }
    }

    // MARK: - Auto-play

    private func startAutoPlay() {
        guard !isAutoPlaying else { return }
        // Auto-play replays the MAIN game line — if the user is in a
        // side variation when they hit play, drop the variation first
        // so the timer doesn't advance an out-of-sync currentPly.
        if isInVariation {
            variation.removeAll()
            variationAnalysis.removeAll()
            rebuildMatchAndAnnounce()
        }
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
        guard analyzer == nil, !plyMoves.isEmpty else { return }

        // Cloud path: Lichess already populated `analysisResults` in
        // init from `game.analysis`. Nothing else to do — the HUD
        // reads straight from that array.
        if !analysisResults.isEmpty { return }

        // Fallback: whole-game atomic batch at depth 15. We collect
        // every `MoveAnalysis` off-screen, then swap into
        // `analysisResults` in one shot so the HUD goes from
        // "Analysing game…" straight to fully classified — no per-ply
        // trickle. Bumped from depth 10 after benchmarking against
        // Lichess cloud: d10 missed 7% of mate positions (mate-in-N
        // showed as +5.0 and got mislabelled); d15 halves that to
        // ~3% at ~2–3× cost per ply. Median cp error vs cloud is
        // ~20cp at either depth — the win comes from the tactical
        // tail, not the median.
        print("[Review] Starting local Stockfish batch — \(plyMoves.count) plies, depth 15")
        let started = Date()
        let analyzer = GameAnalyzer(multiPV: 3)
        self.analyzer = analyzer
        isAnalyzing = true
        analysisTask = Task { @MainActor in
            var collected: [MoveAnalysis] = []
            collected.reserveCapacity(plyMoves.count)
            do {
                let stream = await analyzer.analyzeStream(
                    startPosition: .standardStart,
                    moves: plyMoves,
                    depth: 15
                )
                for try await m in stream {
                    if Task.isCancelled { break }
                    collected.append(m)
                }
                print("[Review] Stream completed with \(collected.count) classifications in \(String(format: "%.1f", -started.timeIntervalSinceNow))s")
            } catch {
                print("[Review] Local Stockfish failed: \(error) (collected \(collected.count) plies before failure)")
            }
            if !Task.isCancelled, !collected.isEmpty {
                self.analysisResults = collected
                self.emitReviewHighlight()
            } else if !Task.isCancelled {
                print("[Review] No classifications produced — panel will show empty state.")
            }
            self.isAnalyzing = false
        }
    }

    func tearDown() {
        stopAutoPlay()
        analysisTask?.cancel()
        analysisTask = nil
        let a = analyzer
        Task { await a?.shutdown() }
    }

    /// Grade a single variation move on local Stockfish. Spins the
    /// engine up lazily so cloud-analyzed reviews don't pay the
    /// Stockfish start-up cost until the user actually branches off.
    /// Streams the result back into `variationAnalysis[index]` as
    /// soon as Stockfish reports a bestmove.
    func analyzeVariationStep(at index: Int) async {
        guard index >= 0, index < variation.count else { return }
        let step = variation[index]

        if analyzer == nil {
            analyzer = GameAnalyzer(multiPV: 3)
        }
        guard let analyzer else { return }

        // Pre-fill a "thinking" slot so the panel shows the move even
        // before Stockfish lands. Quality defaults to `.good` —
        // upgraded once the eval comes back.
        let placeholder = MoveAnalysis(
            id: index,
            san: step.move.uci,
            playedUCI: step.move.uci,
            mover: step.positionBefore.sideToMove,
            playedScoreCp: 0,
            bestScoreCp: 0,
            centipawnLoss: 0,
            winPercentLoss: 0,
            topLines: [],
            quality: .good,
            bookOpening: nil
        )
        while variationAnalysis.count <= index {
            variationAnalysis.append(placeholder)
        }
        variationAnalysis[index] = placeholder

        do {
            // Evaluate the position BEFORE the variation move at a
            // lower depth than main-line review (14 vs 20) so single
            // branches feel snappy — a couple of seconds, not 5+.
            let linesBefore = try await analyzer.evaluatePosition(
                fen: step.positionBefore.fen, depth: 14
            )
            // And the position AFTER, to score the move's resulting
            // eval from the SAME mover's POV.
            let linesAfter = try await analyzer.evaluatePosition(
                fen: step.positionAfter.fen, depth: 14
            )

            // Make sure the variation hasn't been popped while we were
            // computing — if it has, drop the result on the floor.
            guard index < variation.count,
                  variation[index].move == step.move else { return }

            let bestScore = linesBefore.first?.scoreCp ?? 0
            let playedFromAfter = -(linesAfter.first?.scoreCp ?? 0)
            let playedScore = linesBefore
                .first(where: { $0.uci == step.move.uci })?
                .scoreCp ?? playedFromAfter

            let cpLoss = max(0, min(1000, bestScore - playedScore))
            let winLoss = max(
                0.0,
                GameAnalyzer.winPercent(fromCp: bestScore)
                  - GameAnalyzer.winPercent(fromCp: playedScore)
            )

            let materialDelta = GameAnalyzer.materialBalance(
                for: step.positionBefore.sideToMove, in: step.positionAfter
            ) - GameAnalyzer.materialBalance(
                for: step.positionBefore.sideToMove, in: step.positionBefore
            )

            let quality = GameAnalyzer.classify(
                played: step.move.uci,
                best: linesBefore.first?.uci,
                bestScoreCp: bestScore,
                playedScoreCp: playedScore,
                winPercentLoss: winLoss,
                materialDelta: materialDelta,
                lines: linesBefore
            )

            let analysis = MoveAnalysis(
                id: index,
                san: step.move.uci,
                playedUCI: step.move.uci,
                mover: step.positionBefore.sideToMove,
                playedScoreCp: playedScore,
                bestScoreCp: bestScore,
                centipawnLoss: cpLoss,
                winPercentLoss: winLoss,
                topLines: linesBefore,
                quality: quality,
                bookOpening: nil
            )
            if index < variationAnalysis.count {
                variationAnalysis[index] = analysis
            }
        } catch {
            // Non-fatal — the placeholder stays, board still works.
        }
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
        // Variation tip wins — that's what's actually on the board.
        if let idx = variation.indices.last,
           idx < variationAnalysis.count {
            return variationAnalysis[idx]
        }
        guard currentPly >= 0, currentPly < analysisResults.count else { return nil }
        return analysisResults[currentPly]
    }

    var plyLabel: String {
        if isInVariation {
            return "\(currentPly + 1) / \(plyMoves.count) · branch +\(variation.count)"
        }
        return "\(currentPly + 1) / \(plyMoves.count)"
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
