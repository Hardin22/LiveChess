import Foundation

struct CastlingRights: Hashable, Sendable, Codable {

    var whiteKingside: Bool
    var whiteQueenside: Bool
    var blackKingside: Bool
    var blackQueenside: Bool

    init(
        whiteKingside: Bool = false,
        whiteQueenside: Bool = false,
        blackKingside: Bool = false,
        blackQueenside: Bool = false
    ) {
        self.whiteKingside = whiteKingside
        self.whiteQueenside = whiteQueenside
        self.blackKingside = blackKingside
        self.blackQueenside = blackQueenside
    }

    static let initial = CastlingRights(
        whiteKingside: true,
        whiteQueenside: true,
        blackKingside: true,
        blackQueenside: true
    )

    static let none = CastlingRights()
}

extension CastlingRights {
    var fenString: String {
        var s = ""
        if whiteKingside { s += "K" }
        if whiteQueenside { s += "Q" }
        if blackKingside { s += "k" }
        if blackQueenside { s += "q" }
        return s.isEmpty ? "-" : s
    }

    init?(fenString: String) {
        if fenString == "-" {
            self = .none
            return
        }
        var rights = CastlingRights.none
        for ch in fenString {
            switch ch {
            case "K": rights.whiteKingside = true
            case "Q": rights.whiteQueenside = true
            case "k": rights.blackKingside = true
            case "q": rights.blackQueenside = true
            default: return nil
            }
        }
        self = rights
    }
}
