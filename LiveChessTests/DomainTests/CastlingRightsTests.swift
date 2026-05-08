import Testing
@testable import LiveChess

@Suite("CastlingRights")
struct CastlingRightsTests {

    @Test(arguments: [
        "KQkq", "KQk", "Kk", "K", "Q", "k", "q",
        "KQ", "kq", "Kq", "Qk", "-",
    ])
    func fenStringRoundTrip(s: String) throws {
        let parsed = try #require(CastlingRights(fenString: s))
        #expect(parsed.fenString == s)
    }

    @Test func initialHasAllRights() {
        let r = CastlingRights.initial
        #expect(r.whiteKingside)
        #expect(r.whiteQueenside)
        #expect(r.blackKingside)
        #expect(r.blackQueenside)
        #expect(r.fenString == "KQkq")
    }

    @Test func noneHasNoRights() {
        let r = CastlingRights.none
        #expect(!r.whiteKingside)
        #expect(!r.whiteQueenside)
        #expect(!r.blackKingside)
        #expect(!r.blackQueenside)
        #expect(r.fenString == "-")
    }

    @Test(arguments: ["X", "Kx", "abc", "12"])
    func invalidFenStringReturnsNil(s: String) {
        #expect(CastlingRights(fenString: s) == nil)
    }
}
