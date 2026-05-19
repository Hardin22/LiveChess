import Testing
import Foundation
@testable import LiveChess

/// Pure-Swift coverage for `SANConverter` — proves the review pipeline
/// actually understands the SAN strings Lichess returns. No Stockfish,
/// no network, so this stays in the fast unit-test bucket.
@Suite("SANConverter")
@MainActor
struct SANConverterTests {

    /// A classic SAN opening should parse cleanly all the way through
    /// — proves the per-ply ChessKit fallback advances the board for
    /// the next token.
    @Test
    func parsesItalianOpening() {
        let san = "e4 e5 Nf3 Nc6 Bc4 Bc5 c3 Nf6 d4 exd4 cxd4 Bb4+"
        let moves = SANConverter.parse(san)
        #expect(moves.count == 12,
            "Italian opening should parse all 12 plies; got \(moves.count)")

        // Spot-check the first ply: 1.e4 → e2→e4.
        #expect(moves.first?.from.algebraic == "e2")
        #expect(moves.first?.to.algebraic == "e4")
    }

    /// UCI tokens still parse via the fast-path, so the analyzer's
    /// existing UCI test data keeps working unchanged.
    @Test
    func uciFastPathStillWorks() {
        let moves = SANConverter.parse("e2e4 e7e5 g1f3")
        #expect(moves.count == 3)
        #expect(moves[0].from.algebraic == "e2")
        #expect(moves[2].from.algebraic == "g1")
    }

    /// Castling parses on both sides via the SAN annotations
    /// `O-O` (kingside) and `O-O-O` (queenside).
    @Test
    func parsesKingsideCastle() {
        let san = "e4 e5 Nf3 Nc6 Bc4 Bc5 O-O"
        let moves = SANConverter.parse(san)
        #expect(moves.count == 7, "all 7 plies should parse")
        let castle = moves.last!
        #expect(castle.isCastle, "ply 7 (O-O) should set isCastle")
        #expect(castle.from.algebraic == "e1")
        #expect(castle.to.algebraic == "g1")
    }

    /// SAN with check / mate annotations doesn't trip the parser.
    /// Scholar's Mate: 1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6 4.Qxf7#
    @Test
    func parsesScholarsMateWithMateGlyph() {
        let san = "e4 e5 Bc4 Nc6 Qh5 Nf6 Qxf7#"
        let moves = SANConverter.parse(san)
        #expect(moves.count == 7, "all 7 plies including #-annotated mate")
        let mate = moves.last!
        #expect(mate.from.algebraic == "h5")
        #expect(mate.to.algebraic == "f7")
    }

    /// Empty input returns an empty array, not nil / crash.
    @Test
    func emptyInput() {
        #expect(SANConverter.parse("").isEmpty)
        #expect(SANConverter.parse("   ").isEmpty)
    }
}
