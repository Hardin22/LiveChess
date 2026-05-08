import Foundation

/// A complete chess position: piece placement plus move-state metadata.
///
/// `board` is a 64-element array indexed by `Square.index` (`a1 == 0`, `h8 == 63`).
struct Position: Hashable, Sendable {

    var board: [Piece?]
    var sideToMove: Side
    var castling: CastlingRights
    var enPassant: Square?
    var halfmoveClock: Int
    var fullmoveNumber: Int

    init(
        board: [Piece?],
        sideToMove: Side,
        castling: CastlingRights,
        enPassant: Square?,
        halfmoveClock: Int,
        fullmoveNumber: Int
    ) {
        precondition(board.count == 64, "Board must contain exactly 64 squares")
        self.board = board
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    subscript(square: Square) -> Piece? {
        get { board[square.index] }
        set { board[square.index] = newValue }
    }
}

extension Position {
    /// Standard chess starting position.
    static let standardStart: Position = {
        Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")!
    }()
}

// MARK: - FEN

extension Position {

    /// Parses a position from a FEN string. Returns `nil` if any field is malformed.
    init?(fen: String) {
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 6 else { return nil }

        // Piece placement
        var board = [Piece?](repeating: nil, count: 64)
        let ranks = parts[0].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard ranks.count == 8 else { return nil }
        for (rankIdxFromTop, rankStr) in ranks.enumerated() {
            let rank = 7 - rankIdxFromTop
            var file = 0
            for ch in rankStr {
                if let n = ch.wholeNumberValue, (1...8).contains(n) {
                    file += n
                } else if let piece = Piece(fenCharacter: ch) {
                    guard let sq = Square(file: file, rank: rank) else { return nil }
                    board[sq.index] = piece
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }

        // Side to move
        let side: Side
        switch parts[1] {
        case "w": side = .white
        case "b": side = .black
        default: return nil
        }

        // Castling rights
        guard let castling = CastlingRights(fenString: parts[2]) else { return nil }

        // En-passant target square
        let enPassant: Square?
        if parts[3] == "-" {
            enPassant = nil
        } else {
            guard let sq = Square(algebraic: parts[3]) else { return nil }
            enPassant = sq
        }

        // Halfmove clock + fullmove number
        guard let halfmove = Int(parts[4]), halfmove >= 0 else { return nil }
        guard let fullmove = Int(parts[5]), fullmove >= 1 else { return nil }

        self.init(
            board: board,
            sideToMove: side,
            castling: castling,
            enPassant: enPassant,
            halfmoveClock: halfmove,
            fullmoveNumber: fullmove
        )
    }

    /// Serializes this position to FEN.
    var fen: String {
        var placement = ""
        for rankIdx in (0...7).reversed() {
            var emptyRun = 0
            for fileIdx in 0...7 {
                let sq = Square(file: fileIdx, rank: rankIdx)!
                if let piece = self[sq] {
                    if emptyRun > 0 {
                        placement += "\(emptyRun)"
                        emptyRun = 0
                    }
                    placement.append(piece.fenCharacter)
                } else {
                    emptyRun += 1
                }
            }
            if emptyRun > 0 { placement += "\(emptyRun)" }
            if rankIdx > 0 { placement += "/" }
        }
        let sideStr = sideToMove == .white ? "w" : "b"
        let epStr = enPassant?.algebraic ?? "-"
        return "\(placement) \(sideStr) \(castling.fenString) \(epStr) \(halfmoveClock) \(fullmoveNumber)"
    }
}
