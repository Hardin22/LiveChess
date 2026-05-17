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

    let puzzle: LichessPuzzle.PuzzleInfo
    let humanSide: Side
    let startPosition: Position
    let solution: [Move]

    private(set) var match: Match
    private(set) var status: Status = .solving
    private(set) var solveIndex: Int = 0
    private(set) var hintsShown: Int = 0

    private let rules: any RulesEngine

    var moveAppliedHandler: (@MainActor (Move) -> Void)?
    var matchResetHandler: (@MainActor () -> Void)?

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
        await playOpponentReplyIfAny()
        checkSolved()
    }

    // MARK: - Hint / restart / solution reveal

    func showHint() { hintsShown += 1 }

    /// Auto-plays the remaining solution from the current state. Used
    /// by the HUD's "View solution" button when the user wants to see
    /// the rest of the line instead of solving it themselves. Marks
    /// the puzzle as solved at the end so the success badge surfaces.
    func revealSolution() async {
        guard status == .solving, solveIndex < solution.count else { return }
        while solveIndex < solution.count {
            try? await Task.sleep(for: .milliseconds(550))
            if status != .solving { return }
            applyValidated(solution[solveIndex])
            solveIndex += 1
        }
        status = .solved
    }

    /// Source square of the next expected user move; the HUD highlights
    /// it (or the renderer pulses it) when the player asks for a hint.
    var hintSourceSquare: Square? {
        guard status == .solving, solveIndex < solution.count else { return nil }
        return solution[solveIndex].from
    }

    /// Reset back to the puzzle's starting position. Called by the HUD
    /// after `.failed` or as "give up / try again".
    func restart() {
        match.reset(to: startPosition, status: .ongoing)
        status = .solving
        solveIndex = 0
        hintsShown = 0
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
    }

    private func checkSolved() {
        if solveIndex >= solution.count {
            status = .solved
        }
    }
}
