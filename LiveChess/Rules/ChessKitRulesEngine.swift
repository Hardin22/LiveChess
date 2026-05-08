import Foundation
import ChessKit

/// `RulesEngine` implementation backed by `chesskit-swift`.
///
/// Bridging strategy: convert `Position` ↔ `ChessKit.Position` through their
/// FEN strings — both libraries already provide round-tripped FEN, so we
/// don't have to map every internal field by hand. Squares map directly via
/// raw integer index (`a1 == 0`, `h8 == 63` in both libraries).
///
/// Notable workaround: `ChessKit.Board.state` is only correct when read
/// *after* a `Board.move()` call. When a `Board` is initialised straight
/// from a `Position` (no preceding move), its internal `updateState()`
/// evaluates check/mate for `sideToMove.opposite` rather than `sideToMove`.
/// `status(of:history:)` therefore implements the rules itself, using
/// `Board.state` only on a flipped-`sideToMove` copy of the position to
/// answer "is the side-to-move's king in check?".
struct ChessKitRulesEngine: RulesEngine {

    func legalMoves(in position: Position) -> [Move] {
        guard let ckPosition = ChessKit.Position(fen: position.fen) else { return [] }
        let board = ChessKit.Board(position: ckPosition)
        let sideToMove = ckPosition.sideToMove

        var moves: [Move] = []
        for ckPiece in ckPosition.pieces where ckPiece.color == sideToMove {
            let targets = board.legalMoves(forPieceAt: ckPiece.square)
            guard let from = Square(index: ckPiece.square.rawValue) else { continue }
            for ckTarget in targets {
                guard let to = Square(index: ckTarget.rawValue) else { continue }

                let isCastle = ckPiece.kind == .king && abs(from.file - to.file) == 2
                let isEnPassant = ckPiece.kind == .pawn
                    && from.file != to.file
                    && ckPosition.piece(at: ckTarget) == nil

                if ckPiece.kind == .pawn && isPromotionRank(to.rank, for: ckPiece.color) {
                    for promo in [PieceKind.queen, .rook, .bishop, .knight] {
                        moves.append(Move(
                            from: from,
                            to: to,
                            promotion: promo,
                            isCastle: false,
                            isEnPassant: false
                        ))
                    }
                } else {
                    moves.append(Move(
                        from: from,
                        to: to,
                        promotion: nil,
                        isCastle: isCastle,
                        isEnPassant: isEnPassant
                    ))
                }
            }
        }
        return moves
    }

    func legalMoves(from square: Square, in position: Position) -> [Move] {
        legalMoves(in: position).filter { $0.from == square }
    }

    func apply(_ move: Move, to position: Position) throws -> Position {
        guard let ckPosition = ChessKit.Position(fen: position.fen) else {
            throw RulesError.invalidPosition
        }
        guard let ckStart = ChessKit.Square(rawValue: move.from.index),
              let ckEnd = ChessKit.Square(rawValue: move.to.index) else {
            throw RulesError.illegalMove
        }

        var board = ChessKit.Board(position: ckPosition)
        guard let ckMove = board.move(pieceAt: ckStart, to: ckEnd) else {
            throw RulesError.illegalMove
        }

        if case .promotion = board.state {
            guard let promotion = move.promotion else {
                throw RulesError.missingPromotion
            }
            board.completePromotion(of: ckMove, to: bridge(promotion))
        }

        guard let resulting = Position(fen: board.position.fen) else {
            throw RulesError.engineFailure
        }
        return resulting
    }

    func status(of position: Position, history: [Position]) -> GameStatus {
        let moves = legalMoves(in: position)
        let kingInCheck = isSideToMoveInCheck(position: position)

        if moves.isEmpty {
            return kingInCheck
                ? .checkmate(winner: position.sideToMove.opponent)
                : .stalemate
        }

        if hasInsufficientMaterial(position: position) {
            return .drawByInsufficientMaterial
        }

        if position.halfmoveClock >= 100 {
            return .drawByFiftyMoveRule
        }

        if isThreefoldRepetition(position: position, history: history) {
            return .drawByThreefoldRepetition
        }

        return kingInCheck ? .check(position.sideToMove) : .ongoing
    }

    // MARK: - Status helpers

    /// Detects whether the side-to-move's king is attacked. Works around the
    /// init-time `Board.state` direction issue by flipping `sideToMove` in a
    /// throwaway copy of the position: with the flip, ChessKit's internal
    /// `updateState()` evaluates check/mate for our side.
    private func isSideToMoveInCheck(position: Position) -> Bool {
        var flipped = position
        flipped.sideToMove = position.sideToMove.opponent
        flipped.enPassant = nil       // EP target only valid for original mover
        flipped.halfmoveClock = 0     // avoid triggering 50-move during the flip

        guard let ckPosition = ChessKit.Position(fen: flipped.fen) else { return false }
        let board = ChessKit.Board(position: ckPosition)
        let target = bridge(position.sideToMove)

        switch board.state {
        case .check(let color), .checkmate(let color):
            return color == target
        default:
            return false
        }
    }

    private func hasInsufficientMaterial(position: Position) -> Bool {
        let nonKings = position.board.compactMap { $0 }.filter { $0.kind != .king }

        // K vs K
        if nonKings.isEmpty { return true }

        // K + single minor piece vs K
        if nonKings.count == 1 {
            return nonKings[0].kind == .bishop || nonKings[0].kind == .knight
        }

        // K + B vs K + B with both bishops on the same colour complex
        if nonKings.count == 2,
           nonKings.allSatisfy({ $0.kind == .bishop }),
           nonKings[0].color != nonKings[1].color {
            let bishopSquares: [Square] = position.board.enumerated().compactMap { idx, piece in
                guard piece?.kind == .bishop, let sq = Square(index: idx) else { return nil }
                return sq
            }
            guard bishopSquares.count == 2 else { return false }
            let parity1 = (bishopSquares[0].file + bishopSquares[0].rank) % 2
            let parity2 = (bishopSquares[1].file + bishopSquares[1].rank) % 2
            return parity1 == parity2
        }

        return false
    }

    private func isThreefoldRepetition(position: Position, history: [Position]) -> Bool {
        let key = RepetitionKey(position: position)
        var occurrences = 0
        for past in history where RepetitionKey(position: past) == key {
            occurrences += 1
            if occurrences >= 3 { return true }
        }
        return false
    }

    // MARK: - Bridging

    private func isPromotionRank(_ rank: Int, for color: ChessKit.Piece.Color) -> Bool {
        (color == .white && rank == 7) || (color == .black && rank == 0)
    }

    private func bridge(_ kind: PieceKind) -> ChessKit.Piece.Kind {
        switch kind {
        case .pawn: .pawn
        case .knight: .knight
        case .bishop: .bishop
        case .rook: .rook
        case .queen: .queen
        case .king: .king
        }
    }

    private func bridge(_ color: ChessKit.Piece.Color) -> Side {
        color == .white ? .white : .black
    }

    private func bridge(_ side: Side) -> ChessKit.Piece.Color {
        side == .white ? .white : .black
    }
}

/// Repetition equality follows FIDE rules: same piece placement, same side to
/// move, same castling rights, same en-passant possibilities. Halfmove and
/// fullmove counters are intentionally excluded.
private struct RepetitionKey: Hashable {
    let board: [Piece?]
    let sideToMove: Side
    let castling: CastlingRights
    let enPassant: Square?

    init(position: Position) {
        self.board = position.board
        self.sideToMove = position.sideToMove
        self.castling = position.castling
        self.enPassant = position.enPassant
    }
}
