import Testing
@testable import LiveChess

@Suite("Square")
struct SquareTests {

    @Test(arguments: [
        (file: 0, rank: 0, algebraic: "a1"),
        (file: 7, rank: 0, algebraic: "h1"),
        (file: 0, rank: 7, algebraic: "a8"),
        (file: 7, rank: 7, algebraic: "h8"),
        (file: 4, rank: 3, algebraic: "e4"),
        (file: 3, rank: 4, algebraic: "d5"),
    ])
    func fileRankAlgebraicRoundTrip(file: Int, rank: Int, algebraic: String) {
        let bySquare = Square(file: file, rank: rank)
        #expect(bySquare?.algebraic == algebraic)

        let byString = Square(algebraic: algebraic)
        #expect(byString?.file == file)
        #expect(byString?.rank == rank)
    }

    @Test(arguments: [(-1, 0), (8, 0), (0, -1), (0, 8), (10, 10), (-5, -5)])
    func invalidFileRankReturnsNil(file: Int, rank: Int) {
        #expect(Square(file: file, rank: rank) == nil)
    }

    @Test(arguments: ["", "a", "a0", "a9", "i1", "z9", "11", "aa", "abc"])
    func invalidAlgebraicReturnsNil(s: String) {
        #expect(Square(algebraic: s) == nil)
    }

    @Test func indexFromCorners() {
        #expect(Square(algebraic: "a1")?.index == 0)
        #expect(Square(algebraic: "h1")?.index == 7)
        #expect(Square(algebraic: "a8")?.index == 56)
        #expect(Square(algebraic: "h8")?.index == 63)
    }

    @Test func indexRoundTripIsBijection() {
        for i in 0..<64 {
            let sq = Square(index: i)
            #expect(sq != nil)
            #expect(sq?.index == i)
        }
    }

    @Test func invalidIndexReturnsNil() {
        #expect(Square(index: -1) == nil)
        #expect(Square(index: 64) == nil)
        #expect(Square(index: 999) == nil)
    }

    @Test func allSquaresHas64Entries() {
        #expect(Square.all.count == 64)
        #expect(Square.all.first?.algebraic == "a1")
        #expect(Square.all.last?.algebraic == "h8")
    }
}
