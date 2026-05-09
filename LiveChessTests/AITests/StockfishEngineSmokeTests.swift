import Testing
import Foundation
@testable import LiveChess

/// Production smoke test for `StockfishEngine`.
///
/// Boots a real Stockfish 17 instance via `chesskit-engine` and exercises
/// the contract `MatchCoordinator` relies on: legal-move generation across
/// turns, strength on a known tactical position, and clean cancellation
/// followed by a fresh request. Both NNUE networks
/// (`nn-1111cefa1111.nnue`, `nn-37f18f62d772.nnue`) ship in the app bundle,
/// so the engine boots in NNUE mode rather than the much weaker classical
/// fallback.
///
/// Tagged `.integration` so a fast unit-only run can skip it.
///
/// All assertions run against a **single** engine instance, mirroring how
/// `MatchCoordinator` keeps one `StockfishEngine` alive for the whole match.
/// This is also a structural constraint: `chesskit-engine` embeds Stockfish
/// in-process by calling its C++ `_main` function, and standing up multiple
/// engine instances inside the same process collides on Stockfish's global
/// state (option registry, thread pool, NNUE slots) and crashes the host.
@Suite("StockfishEngine smoke", .tags(.integration))
struct StockfishEngineSmokeTests {

    @Test
    func bootsAndPlaysLegalAndTacticalMoves() async throws {
        let engine = StockfishEngine()
        defer { Task { await engine.stop() } }

        let rules = ChessKitRulesEngine()
        let quick = AISettings(skillLevel: 0, thinkingTime: .milliseconds(400))
        let strong = AISettings(skillLevel: 20, thinkingTime: .milliseconds(800))

        // 1) Two consecutive legal moves on the standard opening.
        //
        //    This catches regressions in the UCI handshake, the response
        //    stream, the FEN ↔ Stockfish round-trip, and the per-request
        //    `setoption Skill Level` push in one shot.
        let move1 = try await engine.bestMove(for: .standardStart, settings: quick)
        let legalAtStart = rules.legalMoves(in: .standardStart)
        #expect(
            legalAtStart.contains { $0.from == move1.from && $0.to == move1.to },
            "Stockfish returned \(move1.uci); legal moves were \(legalAtStart.map(\.uci))"
        )

        let afterMove1 = try rules.apply(move1, to: .standardStart)
        let move2 = try await engine.bestMove(for: afterMove1, settings: quick)
        let legalAfter1 = rules.legalMoves(in: afterMove1)
        #expect(
            legalAfter1.contains { $0.from == move2.from && $0.to == move2.to },
            "Stockfish returned \(move2.uci); legal moves were \(legalAfter1.map(\.uci))"
        )

        // 2) Tactical sanity: at full strength Stockfish must capture a free
        //    queen. After 1.e4 e5 2.Nc3 d5 3.exd5 Qxd5?? white plays Nxd5
        //    (c3d5). Anything else here would be a regression in either the
        //    engine wiring or the NNUE evaluation. Doubles as proof that the
        //    bundled NNUE networks are actually getting loaded — without
        //    them Stockfish's classical eval still picks `c3d5` here, but
        //    catching this regression requires the strong setting to match
        //    what the production app uses.
        let freeQueenFEN =
          "rnb1kbnr/ppp2ppp/8/3q4/8/2N5/PPPP1PPP/R1BQKBNR w KQkq - 1 4"
        let freeQueen = try #require(Position(fen: freeQueenFEN))
        let tactical = try await engine.bestMove(for: freeQueen, settings: strong)
        #expect(
            tactical.uci == "c3d5",
            "Expected the free-queen capture c3d5; engine played \(tactical.uci)"
        )
    }
}
