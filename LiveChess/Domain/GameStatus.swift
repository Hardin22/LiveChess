import Foundation

/// The result of evaluating a `Position` (with its history) for game-end conditions.
enum GameStatus: Hashable, Sendable {
    case ongoing
    case check(Side)
    case checkmate(winner: Side)
    case stalemate
    case drawByInsufficientMaterial
    case drawByFiftyMoveRule
    case drawByThreefoldRepetition
}

extension GameStatus {
    var isGameOver: Bool {
        switch self {
        case .ongoing, .check: false
        case .checkmate, .stalemate,
             .drawByInsufficientMaterial,
             .drawByFiftyMoveRule,
             .drawByThreefoldRepetition: true
        }
    }

    var winner: Side? {
        if case .checkmate(let side) = self { return side }
        return nil
    }

    var isDraw: Bool {
        switch self {
        case .stalemate,
             .drawByInsufficientMaterial,
             .drawByFiftyMoveRule,
             .drawByThreefoldRepetition: true
        default: false
        }
    }
}
