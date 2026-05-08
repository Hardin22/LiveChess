import Foundation

enum PieceKind: Hashable, Sendable, Codable, CaseIterable {
    case pawn
    case knight
    case bishop
    case rook
    case queen
    case king
}

struct Piece: Hashable, Sendable, Codable {
    let kind: PieceKind
    let color: Side

    init(_ kind: PieceKind, _ color: Side) {
        self.kind = kind
        self.color = color
    }
}

extension Piece {
    /// Parses a single FEN piece character (`P`, `n`, etc.).
    init?(fenCharacter ch: Character) {
        let lower = Character(ch.lowercased())
        let kind: PieceKind
        switch lower {
        case "p": kind = .pawn
        case "n": kind = .knight
        case "b": kind = .bishop
        case "r": kind = .rook
        case "q": kind = .queen
        case "k": kind = .king
        default: return nil
        }
        self.init(kind, ch.isUppercase ? .white : .black)
    }

    var fenCharacter: Character {
        let lower: Character
        switch kind {
        case .pawn: lower = "p"
        case .knight: lower = "n"
        case .bishop: lower = "b"
        case .rook: lower = "r"
        case .queen: lower = "q"
        case .king: lower = "k"
        }
        return color == .white ? Character(lower.uppercased()) : lower
    }
}
