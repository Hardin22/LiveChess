import Testing
import Foundation
@testable import LiveChess

/// Production smoke test for `GameAnalyzer`.
///
/// Drives the full review pipeline (Stockfish + MultiPV + book lookup
/// + material delta + win% classification) over a short famous game
/// and asserts the bucket distribution is plausible. Not pinned to
/// exact ply-by-ply labels because Stockfish output varies by depth
/// and thread count, but the structural claims should hold across
/// runs and SF versions.
///
/// Tagged `.integration` for the same reason as `StockfishEngineSmoke`
/// — boots a real engine inside the test process.
@Suite("GameAnalyzer smoke", .tags(.integration))
struct GameAnalyzerSmokeTests {

    /// Scholar's Mate: 1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6?? 4.Qxf7#
    ///
    /// Properties we assert about this game's review:
    ///   1. All 7 plies analysed → stream completes with 7 results.
    ///   2. The first two plies (1.e4 e5) hit the bundled opening
    ///      book — classification == .book.
    ///   3. Black's 6th ply (Nf6) is a blunder — allows Qxf7#. The
    ///      analyzer should label it with one of the high-loss
    ///      qualities: blunder, missedWin, or mistake. (Some
    ///      engine + depth combos call it missedWin because the
    ///      position was equal and is now lost, others blunder.)
    @Test
    func scholarsMateClassifiesBlunder() async throws {
        let analyzer = GameAnalyzer(multiPV: 3)
        defer { Task { await analyzer.shutdown() } }

        let uci = ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]
        let moves = uci.compactMap { Move(uci: $0) }
        #expect(moves.count == uci.count, "all UCI strings must parse")

        var results: [MoveAnalysis] = []
        let stream = await analyzer.analyzeStream(
            startPosition: .standardStart,
            moves: moves,
            depth: 14   // lower than UI's 16 to keep the test fast
        )
        for try await m in stream {
            results.append(m)
        }

        #expect(results.count == moves.count, "every ply must be analysed")

        // 1. e4 and 1...e5 are quintessential book moves — should hit
        //    the bundled lichess-org/chess-openings DB.
        let firstWhite = results[0]
        let firstBlack = results[1]
        #expect(firstWhite.quality == .book, "1.e4 must classify as book")
        #expect(firstBlack.quality == .book, "1...e5 must classify as book")

        // Black's losing move at ply 5 (index 5, 6th ply) is Nf6 — the
        // move that allows Qxf7#. We don't lock onto a single bucket
        // because depending on depth Stockfish may already see the
        // mate at the previous position (then Nf6 is just a confirming
        // move along the lost PV → could be best/excellent), but in
        // most setups the position before Nf6 is still roughly equal
        // and Nf6 swings the eval massively → blunder / missedWin.
        let nf6 = results[5]
        let highCost = [MoveQuality.blunder, .missedWin, .mistake]
            .contains(nf6.quality) || nf6.winPercentLoss >= 10
        let detail = "got \(nf6.quality) winLoss=\(nf6.winPercentLoss)"
        #expect(highCost, "Nf6 must surface as a high-cost move; \(detail)")

        // Every analysed (non-book) ply should carry up to MultiPV
        // candidate lines.
        for r in results where r.quality != .book {
            #expect(r.topLines.count <= 3, "MultiPV cap respected")
            #expect(r.topLines.first?.pv.isEmpty == false || r.bookOpening != nil,
                "best line must have a PV unless this was a book hit")
        }
    }

    /// Material-delta brilliancy unit test — exercises the pure-Swift
    /// `materialBalance(for:in:)` helper that brilliant detection
    /// keys off, without spinning Stockfish. Cheap, deterministic.
    @Test
    func materialBalanceCountsCorrectly() {
        let start = Position.standardStart
        // Standard start: each side has 8P+2N+2B+2R+1Q = 8+6+6+10+9 = 39
        let white = GameAnalyzer.materialBalance(for: .white, in: start)
        let black = GameAnalyzer.materialBalance(for: .black, in: start)
        #expect(white == 39, "standard start white material")
        #expect(black == 39, "standard start black material")
    }

    /// Win-% mapping check — the sigmoid must saturate near ±100 for
    /// extreme cp values and pass through 50 at 0.
    @Test
    func winPercentMappingShape() {
        #expect(GameAnalyzer.winPercent(fromCp: 0) == 50)
        #expect(GameAnalyzer.winPercent(fromCp: 400) > 80)   // tanh(1) ≈ 0.76
        #expect(GameAnalyzer.winPercent(fromCp: 400) < 95)
        #expect(GameAnalyzer.winPercent(fromCp: -400) < 20)
        #expect(GameAnalyzer.winPercent(fromCp: 2000) > 99)
    }
}
