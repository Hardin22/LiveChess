import Foundation

/// A chess move, expressed as origin + destination square plus optional flags.
///
/// `isCastle` and `isEnPassant` are *advisory* flags that the rules engine
/// fills in when it identifies a move as such. A move parsed from UCI alone
/// will have them `false`; the rules engine resolves the truth from the
/// originating position.
struct Move: Hashable, Sendable, Codable {

    let from: Square
    let to: Square
    let promotion: PieceKind?
    let isCastle: Bool
    let isEnPassant: Bool

    init(
        from: Square,
        to: Square,
        promotion: PieceKind? = nil,
        isCastle: Bool = false,
        isEnPassant: Bool = false
    ) {
        self.from = from
        self.to = to
        self.promotion = promotion
        self.isCastle = isCastle
        self.isEnPassant = isEnPassant
    }
}

extension Move {
    /// Long algebraic notation in lowercase, used by UCI engines.
    /// Examples: `e2e4`, `e7e8q`, `e1g1` (kingside castle).
    var uci: String {
        var s = from.algebraic + to.algebraic
        if let p = promotion {
            s.append(promotionChar(for: p))
        }
        return s
    }

    /// Parses a UCI move. Castle/en-passant flags are not inferred and remain
    /// `false`; the rules engine sets them when applying the move.
    init?(uci: String) {
        guard uci.count == 4 || uci.count == 5 else { return nil }
        let chars = Array(uci)
        guard let from = Square(algebraic: String(chars[0...1])),
              let to = Square(algebraic: String(chars[2...3])) else { return nil }
        var promo: PieceKind? = nil
        if uci.count == 5 {
            switch chars[4] {
            case "n": promo = .knight
            case "b": promo = .bishop
            case "r": promo = .rook
            case "q": promo = .queen
            default: return nil
            }
        }
        self.init(from: from, to: to, promotion: promo)
    }

    private func promotionChar(for kind: PieceKind) -> Character {
        switch kind {
        case .knight: "n"
        case .bishop: "b"
        case .rook: "r"
        case .queen: "q"
        case .pawn, .king: "?"
        }
    }

    /// Returns a copy of this move with `isCastle` / `isEnPassant`
    /// derived from the piece sitting at `from` in `position`. Use this
    /// to augment a move parsed from an external UCI string (Stockfish,
    /// Lichess) so downstream consumers — particularly the renderer —
    /// can drive the right animation. The rules engine itself doesn't
    /// need the flags to apply the move correctly, but the renderer's
    /// castling-rook slide and en-passant capture fade are gated on
    /// them.
    func augmentingFlags(in position: Position) -> Move {
        guard let piece = position[from] else { return self }
        let fileDelta = abs(from.file - to.file)
        let castling = piece.kind == .king && fileDelta == 2
        // En-passant: pawn moves diagonally to an empty square. The
        // captured pawn sits on the same rank as the moving pawn's
        // origin (not the destination), but the renderer doesn't need
        // that detail — just the flag so it can fade the right piece.
        let enPassant = piece.kind == .pawn
            && fileDelta == 1
            && position[to] == nil
        return Move(
            from: from,
            to: to,
            promotion: promotion,
            isCastle: castling,
            isEnPassant: enPassant
        )
    }
}
