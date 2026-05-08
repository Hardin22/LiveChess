import Testing
@testable import LiveChess

@Suite("Move")
struct MoveTests {

    @Test(arguments: [
        "e2e4", "e7e5", "g1f3", "b8c6",
        "a1h8", "h8a1", "e1g1", "e1c1",
    ])
    func uciRoundTripWithoutPromotion(uci: String) throws {
        let move = try #require(Move(uci: uci))
        #expect(move.uci == uci)
        #expect(move.promotion == nil)
        #expect(move.isCastle == false)
        #expect(move.isEnPassant == false)
    }

    @Test(arguments: [
        ("e7e8q", PieceKind.queen),
        ("a7a8n", PieceKind.knight),
        ("h7h8r", PieceKind.rook),
        ("c2c1b", PieceKind.bishop),
    ])
    func uciRoundTripWithPromotion(uci: String, expected: PieceKind) throws {
        let move = try #require(Move(uci: uci))
        #expect(move.promotion == expected)
        #expect(move.uci == uci)
    }

    @Test(arguments: ["", "e2", "e2e", "e2e4q4", "z2z4", "e2e9", "e2e4x"])
    func invalidUCIReturnsNil(s: String) {
        #expect(Move(uci: s) == nil)
    }

    @Test func explicitInitDefaults() throws {
        let from = try #require(Square(algebraic: "e2"))
        let to = try #require(Square(algebraic: "e4"))
        let m = Move(from: from, to: to)
        #expect(m.promotion == nil)
        #expect(!m.isCastle)
        #expect(!m.isEnPassant)
        #expect(m.uci == "e2e4")
    }
}
