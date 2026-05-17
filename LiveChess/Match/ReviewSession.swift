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
        guard analyzer == nil, !plyMoves.isEmpty else { return }
        let analyzer = GameAnalyzer(multiPV: 3)
        self.analyzer = analyzer
        isAnalyzing = true
        analysisTask = Task { @MainActor in
            do {
                let stream = await analyzer.analyzeStream(
                    startPosition: .standardStart,
                    moves: plyMoves,
                    depth: 16
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
}
