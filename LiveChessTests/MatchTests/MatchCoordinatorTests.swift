import Testing
@testable import LiveChess

@Suite("MatchCoordinator")
@MainActor
struct MatchCoordinatorTests {

    // MARK: - Helpers

    private func makeMove(from: String, to: String) -> Move {
        Move(from: Square(algebraic: from)!, to: Square(algebraic: to)!)
    }

    private func makeCoordinator(
        rules: MockRulesEngine,
        ai: MockAIEngine,
        white: MatchCoordinator.SideController,
        black: MatchCoordinator.SideController
    ) -> (MatchCoordinator, Match) {
        let match = Match()
        let coord = MatchCoordinator(
            match: match,
            rules: rules,
            ai: ai,
            white: white,
            black: black
        )
        return (coord, match)
    }

    // MARK: - Tests

    @Test
    func humanVsHumanRecordsBothMoves() {
        let rules = MockRulesEngine()
        let ai = MockAIEngine()
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .human, black: .human
        )
        coord.start()

        let whiteMove = makeMove(from: "e2", to: "e4")
        let blackMove = makeMove(from: "e7", to: "e5")
        coord.submitHumanMove(whiteMove)
        coord.submitHumanMove(blackMove)

        #expect(match.moves == [whiteMove, blackMove])
        #expect(rules.applyCallCount == 2)
    }

    @Test
    func humanMoveTriggersAITurn() async {
        let rules = MockRulesEngine()
        let aiMove = makeMove(from: "e7", to: "e5")
        let ai = MockAIEngine(moves: [aiMove])
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .human, black: .ai(AISettings())
        )
        coord.start()

        let humanMove = makeMove(from: "e2", to: "e4")
        coord.submitHumanMove(humanMove)
        #expect(coord.isAIThinking)

        await coord.waitForAI()

        #expect(!coord.isAIThinking)
        #expect(match.moves == [humanMove, aiMove])
        let aiCalls = await ai.bestMoveCallCount
        #expect(aiCalls == 1)
    }

    @Test
    func startWithAIToMoveTriggersAIImmediately() async {
        let rules = MockRulesEngine()
        let aiOpening = makeMove(from: "e2", to: "e4")
        let ai = MockAIEngine(moves: [aiOpening])
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .ai(AISettings()), black: .human
        )

        coord.start()
        #expect(coord.isAIThinking)
        await coord.waitForAI()

        #expect(match.moves == [aiOpening])
    }

    @Test
    func humanMoveDuringAITurnIsIgnored() async {
        let rules = MockRulesEngine()
        let aiMove = makeMove(from: "e2", to: "e4")
        let ai = MockAIEngine(moves: [aiMove], thinkingDelay: .milliseconds(80))
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .ai(AISettings()), black: .human
        )

        coord.start()
        // While AI is thinking, attempt a human submission for white.
        coord.submitHumanMove(makeMove(from: "a2", to: "a3"))
        // Should be rejected because side-to-move is white = AI.
        #expect(rules.applyCallCount == 0)

        await coord.waitForAI()
        #expect(match.moves == [aiMove])
    }

    @Test
    func gameOverStopsAIScheduling() async {
        let rules = MockRulesEngine()
        rules.statusValue = .checkmate(winner: .white)
        let ai = MockAIEngine(moves: [makeMove(from: "e7", to: "e5")])
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .human, black: .ai(AISettings())
        )

        coord.submitHumanMove(makeMove(from: "e2", to: "e4"))
        // Human move applied, status is now checkmate → AI must NOT be triggered.
        #expect(!coord.isAIThinking)
        #expect(match.status == .checkmate(winner: .white))
        let aiCalls = await ai.bestMoveCallCount
        #expect(aiCalls == 0)
    }

    @Test
    func newGameResetsMatchAndState() async {
        let rules = MockRulesEngine()
        let ai = MockAIEngine(moves: [
            makeMove(from: "e7", to: "e5"),    // first game
            makeMove(from: "c7", to: "c5"),    // after newGame
        ])
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .human, black: .ai(AISettings())
        )

        coord.submitHumanMove(makeMove(from: "e2", to: "e4"))
        await coord.waitForAI()
        #expect(match.moves.count == 2)

        coord.newGame()
        #expect(match.moves.isEmpty)
        #expect(match.currentPosition == .standardStart)
        #expect(coord.lastError == nil)
    }

    @Test
    func illegalMoveSetsLastError() {
        let rules = MockRulesEngine()
        rules.applyError = .illegalMove
        let ai = MockAIEngine()
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .human, black: .human
        )

        coord.submitHumanMove(makeMove(from: "e2", to: "e5"))
        #expect(match.moves.isEmpty)
        if let err = coord.lastError as? RulesError {
            #expect(err == .illegalMove)
        } else {
            Issue.record("Expected RulesError.illegalMove, got \(String(describing: coord.lastError))")
        }
    }

    @Test
    func aiVsAIChainsTurns() async {
        let rules = MockRulesEngine()
        let move1 = makeMove(from: "e2", to: "e4")
        let move2 = makeMove(from: "e7", to: "e5")
        let move3 = makeMove(from: "g1", to: "f3")
        let ai = MockAIEngine(moves: [move1, move2, move3])
        rules.statusValue = .ongoing
        let settings = AISettings()
        let (coord, match) = makeCoordinator(
            rules: rules, ai: ai, white: .ai(settings), black: .ai(settings)
        )

        coord.start()
        // Drain three chained AI tasks.
        for _ in 0..<3 {
            await coord.waitForAI()
        }

        #expect(match.moves.count == 3)
    }
}
