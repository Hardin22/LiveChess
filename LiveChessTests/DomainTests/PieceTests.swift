import Testing
@testable import LiveChess

@Suite("Piece")
struct PieceTests {

    @Test(arguments: [
        ("P", PieceKind.pawn, Side.white),
        ("N", PieceKind.knight, Side.white),
        ("B", PieceKind.bishop, Side.white),
        ("R", PieceKind.rook, Side.white),
        ("Q", PieceKind.queen, Side.white),
        ("K", PieceKind.king, Side.white),
        ("p", PieceKind.pawn, Side.black),
        ("n", PieceKind.knight, Side.black),
        ("b", PieceKind.bishop, Side.black),
        ("r", PieceKind.rook, Side.black),
        ("q", PieceKind.queen, Side.black),
        ("k", PieceKind.king, Side.black),
    ])
    func fenCharacterRoundTrip(char: String, kind: PieceKind, color: Side) {
        let ch = Character(char)
        let piece = Piece(fenCharacter: ch)
        #expect(piece?.kind == kind)
        #expect(piece?.color == color)
        #expect(piece?.fenCharacter == ch)
    }

    @Test(arguments: ["x", "1", " ", "", "X", "?", "Z"])
    func invalidFENCharacterReturnsNil(s: String) {
        guard let ch = s.first else {
            #expect(s.isEmpty)
            return
        }
        #expect(Piece(fenCharacter: ch) == nil)
    }

    @Test func sideOpponentInvolutive() {
        #expect(Side.white.opponent == .black)
        #expect(Side.black.opponent == .white)
        #expect(Side.white.opponent.opponent == .white)
    }
}
