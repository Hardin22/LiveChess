import Foundation
import ChessKit

/// Converts SAN (Standard Algebraic Notation) move strings to the
/// project's domain `Move` type by stepping a `ChessKit.Board` through
/// each ply. Used by the review pipeline because Lichess's
/// `/api/games/user/{username}` + `/api/game/{id}` endpoints return
/// the move list as space-separated SAN ("e4 e5 Nf3 Nc6 Bb5 a6 …"),
/// but `Move(uci:)` only accepts UCI ("e2e4 e7e5 g1f3 b8c6 …"). The
/// SAN-only path was silently producing an empty Move array → review
/// never started → "Review" button looked dead.
@MainActor
enum SANConverter {

    /// Parse a space-separated SAN string into a sequence of domain
    /// moves, played from `startPosition`. Returns the converted
    /// moves up to the first token that fails to parse (best-effort
    /// — better to show a partial review than no review at all).
    ///
    /// The string may also contain UCI tokens (`e2e4`) — those are
    /// detected first and converted directly via `Move(uci:)`. So a
    /// pre-cleaned UCI line still works through this entry point.
    static func parse(
        _ raw: String,
        startPosition: Position = .standardStart
    ) -> [Move] {
        let tokens = raw.split(separator: " ",
                               omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return [] }
        guard var ck = ChessKit.Position(fen: startPosition.fen) else {
            return []
        }
        var board = ChessKit.Board(position: ck)
        var out: [Move] = []

        for raw in tokens {
            let san = String(raw)
            // Try a direct UCI parse first — the existing analyzer
            // tests feed UCI through here too, and skipping the SAN
            // lookup for those is much cheaper.
            if let uciMove = Move(uci: san),
               let played = try? ChessKitRulesEngineMoveHelper
                .applyUCI(uciMove, on: &board, ck: &ck) {
                out.append(played)
                continue
            }

            // Otherwise resolve SAN against the current position via
            // ChessKit, then translate back to the domain Move.
            guard let ckMove = ChessKit.Move(san: san, position: ck) else {
                break
            }
            guard let played = try? ChessKitRulesEngineMoveHelper
                .applyChessKit(ckMove, on: &board, ck: &ck) else {
                break
            }
            out.append(played)
        }
        return out
    }
}

/// Small bridge that lives next to `ChessKitRulesEngine` and exposes
/// "apply this move to a live ChessKit.Board, advance both the board
/// and the position, return the domain Move that landed". Lifted out
/// so `SANConverter` doesn't have to duplicate the
/// `Board.move(pieceAt:to:) + completePromotion + bridge` dance.
private enum ChessKitRulesEngineMoveHelper {

    static func applyUCI(
        _ move: Move,
        on board: inout ChessKit.Board,
        ck: inout ChessKit.Position
    ) throws -> Move {
        guard let from = ChessKit.Square(rawValue: move.from.index),
              let to = ChessKit.Square(rawValue: move.to.index),
              let ckMove = board.move(pieceAt: from, to: to) else {
            throw NSError(domain: "san", code: 1)
        }
        if case .promotion = board.state {
            board.completePromotion(of: ckMove,
                                    to: bridge(move.promotion ?? .queen))
        }
        ck = board.position
        return move
    }

    static func applyChessKit(
        _ ckMove: ChessKit.Move,
        on board: inout ChessKit.Board,
        ck: inout ChessKit.Position
    ) throws -> Move {
        // ckMove.start / .end are ChessKit.Square (rawValue 0..<64).
        guard let from = Square(index: ckMove.start.rawValue),
              let to = Square(index: ckMove.end.rawValue) else {
            throw NSError(domain: "san", code: 2)
        }
        // Play it on the live board so ck advances.
        guard let played = board.move(pieceAt: ckMove.start, to: ckMove.end) else {
            throw NSError(domain: "san", code: 3)
        }
        var promotion: PieceKind?
        if case .promotion = board.state {
            // SAN strings like "e8=Q" carry the promotion choice on
            // ckMove.promotedPiece. Default to queen if unspecified.
            let chosen = ckMove.promotedPiece?.kind ?? .queen
            board.completePromotion(of: played, to: chosen)
            promotion = bridgeBack(chosen)
        }
        ck = board.position
        let isCastle: Bool
        if case .castle = ckMove.result { isCastle = true }
        else { isCastle = false }
        // En passant: a pawn capture where the result is .move (no
        // captured piece encoded — the captured pawn sits on a
        // different square). chesskit-swift folds the captured pawn
        // into .capture so this should be rare; treat it as a
        // diagonal pawn move without a .capture result.
        let isEnPassant: Bool = {
            if ckMove.piece.kind != .pawn { return false }
            if from.file == to.file { return false }
            if case .capture = ckMove.result { return false }
            return true
        }()
        return Move(
            from: from,
            to: to,
            promotion: promotion,
            isCastle: isCastle,
            isEnPassant: isEnPassant
        )
    }

    private static func bridge(_ kind: PieceKind) -> ChessKit.Piece.Kind {
        switch kind {
        case .pawn:   return .pawn
        case .knight: return .knight
        case .bishop: return .bishop
        case .rook:   return .rook
        case .queen:  return .queen
        case .king:   return .king
        }
    }

    private static func bridgeBack(_ kind: ChessKit.Piece.Kind) -> PieceKind {
        switch kind {
        case .pawn:   return .pawn
        case .knight: return .knight
        case .bishop: return .bishop
        case .rook:   return .rook
        case .queen:  return .queen
        case .king:   return .king
        }
    }
}
