import Foundation

/// Side to move / piece color in chess.
enum Side: Hashable, Sendable, Codable, CaseIterable {
    case white
    case black

    var opponent: Side {
        switch self {
        case .white: .black
        case .black: .white
        }
    }
}
