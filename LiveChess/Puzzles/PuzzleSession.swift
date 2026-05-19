import Foundation
import Observation

/// `MatchSession` implementation for solving a Lichess puzzle on the
/// immersive 3-D board. Unlike `MatchCoordinator` (vs. Stockfish) or
/// `LichessMatchSession` (vs. a remote human), the puzzle source is a
/// fixed solution sequence — the user plays one side, the app
/// auto-plays the opponent's expected reply.
///
/// State:
///   * `solveIndex` — index into `solution` of the move expected next.
///     The user's turn is when the position's side-to-move matches
///     `humanSide`; the opponent's auto-replies fire on the other
///     parity.
///   * `status: PuzzleStatus` — `.solving / .solved / .failed`. A
///     wrong human move sets `.failed`; the HUD's "Try again" button
///     calls `restart()` to put the user back at the start.
@MainActor
@Observable
final class PuzzleSession: MatchSession {

    enum Status: Sendable, Equatable {
        case solving
        case solved
        case failed
    }

    /// Progressive hint disclosure. The user presses Hint once to see
    /// WHICH piece moves (`.source`), and a second time to see WHERE
    /// it goes (`.fullMove`). Auto-resets to `.none` on each correct
    /// move so each puzzle ply starts fresh.
    enum HintLevel: Sendable, Equatable {
        case none
        case source     // source square highlighted
        case fullMove   // source + destination highlighted
    }

    let puzzle: LichessPuzzle.PuzzleInfo
    let humanSide: Side
    let startPosition: Position
    let solution: [Move]

    private(set) var match: Match
    private(set) var status: Status = .solving
    private(set) var solveIndex: Int = 0
    private(set) var hintLevel: HintLevel = .none

    private let rules: any RulesEngine

    var moveAppliedHandler: (@MainActor (Move) -> Void)?
    var matchResetHandler: (@MainActor () -> Void)?
    /// Fires when the hint state advances. Carries the new level plus
    /// the expected next move so the renderer can light the source
    /// and/or destination square. Set by `ChessSceneView` once at
    /// scene-build time.
    var hintHandler: (@MainActor (HintLevel, Move) -> Void)?

    /// Returns `nil` if the puzzle payload is missing the fields the
    /// session needs (FEN + at least one solution move).
    init?(puzzle: LichessPuzzle,
          rules: any RulesEngine = ChessKitRulesEngine()) {
        let info = puzzle.puzzle
        let parsedSolution = (info.solution ?? [])
            .compactMap { Move(uci: $0) }
        guard !parsedSolution.isEmpty,
              let fenStr = info.fen,
              let start = Position(fen: fenStr) else { return nil }

        self.puzzle = info
        self.startPosition = start
        self.solution = parsedSolution
        self.match = Match(startPosition: start)
        self.humanSide = start.sideToMove
        self.rules = rules
    }

    // MARK: - MatchSession

    var isHumanTurn: Bool {
        status == .solving
            && solveIndex < solution.count
            && match.currentPosition.sideToMove == humanSide
    }

    func legalMoves(from square: Square) -> [Move] {
        guard isHumanTurn else { return [] }
        return rules.legalMoves(from: square, in: match.currentPosition)
    }

    func submitMove(_ move: Move) async {
        guard isHumanTurn, solveIndex < solution.count else { return }
        let expected = solution[solveIndex]
        guard move.from == expected.from,
              move.to == expected.to,
              move.promotion == expected.promotion else {
            // Wrong move — flag as failed; HUD shows "Try again".
            status = .failed
            return
        }
        applyValidated(move)
        solveIndex += 1
        resetHint()
        await playOpponentReplyIfAny()
        checkSolved()
    }

    // MARK: - Hint / restart

    /// Advances the hint disclosure by one step. The user presses once
    /// to see the source square (`.source`), again to see the full move
    /// (`.fullMove`). A third press is a no-op so the player can't
    /// auto-reveal further plies of the line.
    func showHint() {
        guard status == .solving, let next = expectedNextMove else { return }
        switch hintLevel {
        case .none:     hintLevel = .source
        case .source:   hintLevel = .fullMove
        case .fullMove: return
        }
        hintHandler?(hintLevel, next)
    }

    /// Clears any visible hint overlay and resets the disclosure stage.
    /// Called automatically when the user makes a correct move, when
    /// the puzzle restarts, and after an opponent reply. The renderer
    /// receives `(.none, move)` so it knows to remove the overlay.
    func resetHint() {
        guard hintLevel != .none else { return }
        let move = expectedNextMove
            ?? solution[max(0, min(solveIndex, solution.count - 1))]
        hintLevel = .none
        hintHandler?(.none, move)
    }

    /// The move the puzzle is waiting for the user to play. `nil` once
    /// the line is complete.
    var expectedNextMove: Move? {
        guard status == .solving, solveIndex < solution.count else { return nil }
        return solution[solveIndex]
    }

    /// Reset back to the puzzle's starting position. Called by the HUD
    /// after `.failed` or as "give up / try again".
    func restart() {
        match.reset(to: startPosition, status: .ongoing)
        status = .solving
        solveIndex = 0
        resetHint()
        matchResetHandler?()
    }

    // MARK: - Internals

    private func applyValidated(_ move: Move) {
        do {
            let next = try rules.apply(move, to: match.currentPosition)
            let newStatus = rules.status(of: next, history: match.positions)
            match.apply(move: move, resulting: next, status: newStatus)
            moveAppliedHandler?(move)
        } catch {
            status = .failed
        }
    }

    private func playOpponentReplyIfAny() async {
        guard status == .solving, solveIndex < solution.count else { return }
        guard match.currentPosition.sideToMove != humanSide else { return }
        try? await Task.sleep(for: .milliseconds(550))
        applyValidated(solution[solveIndex])
        solveIndex += 1
        resetHint()
    }

    private func checkSolved() {
        if solveIndex >= solution.count {
            status = .solved
        }
    }
}
