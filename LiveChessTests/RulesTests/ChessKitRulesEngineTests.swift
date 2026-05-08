import Testing
@testable import LiveChess

@Suite("ChessKitRulesEngine")
struct ChessKitRulesEngineTests {

    let engine = ChessKitRulesEngine()

    // MARK: - legalMoves

    @Test func startingPositionHas20LegalMoves() {
        let moves = engine.legalMoves(in: .standardStart)
        #expect(moves.count == 20)
    }

    @Test func startingPositionPawnE2Has2LegalMoves() throws {
        let e2 = try #require(Square(algebraic: "e2"))
        let moves = engine.legalMoves(from: e2, in: .standardStart)
        #expect(moves.count == 2)
        let destinations = Set(moves.map(\.to.algebraic))
        #expect(destinations == ["e3", "e4"])
    }

    @Test func startingPositionKnightG1Has2LegalMoves() throws {
        let g1 = try #require(Square(algebraic: "g1"))
        let moves = engine.legalMoves(from: g1, in: .standardStart)
        let destinations = Set(moves.map(\.to.algebraic))
        #expect(destinations == ["f3", "h3"])
    }

    @Test func startingPositionRookA1HasNoMoves() throws {
        let a1 = try #require(Square(algebraic: "a1"))
        #expect(engine.legalMoves(from: a1, in: .standardStart).isEmpty)
    }

    // MARK: - apply

    @Test func applyE2E4ProducesExpectedPosition() throws {
        let e2 = try #require(Square(algebraic: "e2"))
        let e4 = try #require(Square(algebraic: "e4"))
        let move = Move(from: e2, to: e4)

        let after = try engine.apply(move, to: .standardStart)
        #expect(after.fen == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        #expect(after.sideToMove == .black)
    }

    @Test func applyIllegalMoveThrows() throws {
        let e2 = try #require(Square(algebraic: "e2"))
        let e5 = try #require(Square(algebraic: "e5"))    // pawn can't jump 3 squares
        let move = Move(from: e2, to: e5)
        #expect(throws: RulesError.illegalMove) {
            _ = try engine.apply(move, to: .standardStart)
        }
    }

    @Test func applyPawnPromotionRequiresPromotionField() throws {
        // White pawn on e7, black king on a8, white king on a1: white to play e8=Q
        let position = try #require(Position(fen: "k7/4P3/8/8/8/8/8/K7 w - - 0 1"))
        let e7 = try #require(Square(algebraic: "e7"))
        let e8 = try #require(Square(algebraic: "e8"))
        let withoutPromo = Move(from: e7, to: e8)
        #expect(throws: RulesError.missingPromotion) {
            _ = try engine.apply(withoutPromo, to: position)
        }
        let withPromo = Move(from: e7, to: e8, promotion: .queen)
        let after = try engine.apply(withPromo, to: position)
        let e8Sq = try #require(Square(algebraic: "e8"))
        #expect(after[e8Sq] == Piece(.queen, .white))
    }

    @Test func legalMovesIncludePromotionVariants() throws {
        // White pawn on e7, white king on a1, black king on a8: 4 promotion moves expected
        let position = try #require(Position(fen: "k7/4P3/8/8/8/8/8/K7 w - - 0 1"))
        let e7 = try #require(Square(algebraic: "e7"))
        let pawnMoves = engine.legalMoves(from: e7, in: position)
        let promotions = Set(pawnMoves.compactMap { $0.promotion })
        #expect(promotions == [.queen, .rook, .bishop, .knight])
    }

    // MARK: - status

    @Test func statusOnStartPositionIsOngoing() {
        let status = engine.status(of: .standardStart, history: [.standardStart])
        #expect(status == .ongoing)
    }

    @Test func foolsMateIsCheckmateWithBlackWinner() throws {
        // After 1.f3 e5 2.g4 Qh4# — White's king is checkmated, Black wins.
        let foolsMate = try #require(
            Position(fen: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
        )
        let status = engine.status(of: foolsMate, history: [foolsMate])
        #expect(status == .checkmate(winner: .black))
    }

    @Test func classicStalemateIsDetected() throws {
        // Black to move, king on a8, no legal moves, not in check.
        let stalemate = try #require(Position(fen: "k7/8/1Q6/2K5/8/8/8/8 b - - 0 1"))
        let status = engine.status(of: stalemate, history: [stalemate])
        #expect(status == .stalemate)
    }

    @Test func inCheckButNotMateReportsCheck() throws {
        // White king on e1 attacked by an undefended black queen on e2;
        // Kxe2 is legal, so it's check but not mate.
        let position = try #require(
            Position(fen: "k7/8/8/8/8/8/4q3/4K3 w - - 0 1")
        )
        let status = engine.status(of: position, history: [position])
        #expect(status == .check(.white))
    }
}
