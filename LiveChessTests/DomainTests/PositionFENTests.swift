import Testing
@testable import LiveChess

@Suite("Position FEN")
struct PositionFENTests {

    static let knownFENs: [String] = [
        // Standard starting position
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        // After 1. e4
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
        // After 1. e4 e5
        "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
        // Kiwipete (classic perft test position)
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        // Position 4 (Lasker)
        "rnbqkb1r/pp1p1pPp/8/2p1pP2/1P1P4/3P3P/P1P1P3/RNBQKBNR w KQkq e6 0 1",
        // Endgame: only kings
        "8/8/8/4k3/8/8/4K3/8 w - - 0 1",
        // Black to move
        "8/8/8/8/8/8/8/k1K5 b - - 50 75",
    ]

    @Test(arguments: knownFENs)
    func fenRoundTripPreservesAllFields(fen: String) throws {
        let position = try #require(Position(fen: fen))
        #expect(position.fen == fen)
    }

    @Test func standardStartHasCorrectFEN() {
        let start = Position.standardStart
        #expect(start.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }

    @Test func standardStartHasWhiteToMove() {
        #expect(Position.standardStart.sideToMove == .white)
    }

    @Test func standardStartHas32Pieces() {
        let start = Position.standardStart
        let pieces = start.board.compactMap { $0 }
        #expect(pieces.count == 32)
    }

    @Test func startingPositionPiecePlacement() throws {
        let start = Position.standardStart
        let e1 = try #require(Square(algebraic: "e1"))
        let e8 = try #require(Square(algebraic: "e8"))
        let a1 = try #require(Square(algebraic: "a1"))
        let h8 = try #require(Square(algebraic: "h8"))
        let e2 = try #require(Square(algebraic: "e2"))
        let e4 = try #require(Square(algebraic: "e4"))
        #expect(start[e1] == Piece(.king, .white))
        #expect(start[e8] == Piece(.king, .black))
        #expect(start[a1] == Piece(.rook, .white))
        #expect(start[h8] == Piece(.rook, .black))
        #expect(start[e2] == Piece(.pawn, .white))
        #expect(start[e4] == nil)
    }

    @Test(arguments: [
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR",                         // missing fields
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1",            // invalid side
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",                    // 7 ranks
        "rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",           // bad rank length
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq xy 0 1",          // bad EP
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - x 1",           // bad halfmove
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0",           // fullmove < 1
    ])
    func invalidFENReturnsNil(s: String) {
        #expect(Position(fen: s) == nil)
    }
}
