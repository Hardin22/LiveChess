import Foundation

/// In-memory lookup over the lichess-org/chess-openings dataset
/// (~3 700 named opening positions, EPD-keyed). Used by
/// `GameAnalyzer` to label a move as book theory and skip engine
/// analysis for it — saves ~5–15 s per game on a typical opening.
///
/// EPD = first FOUR fields of FEN (board placement + side-to-move
/// + castling rights + en-passant target). Halfmove clock and
/// fullmove number are stripped so transposed move orders hit the
/// same entry.
final class OpeningBook: @unchecked Sendable {

    struct Entry: Sendable, Hashable {
        let eco: String
        let name: String
    }

    static let shared = OpeningBook()

    private let entries: [String: Entry]

    private init() {
        var map: [String: Entry] = [:]
        if let url = Bundle.main.url(forResource: "openings", withExtension: "tsv"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let epd = String(parts[0])
                let eco = String(parts[1])
                let name = String(parts[2])
                map[epd] = Entry(eco: eco, name: name)
            }
        }
        self.entries = map
    }

    /// Returns the matching opening entry for `position` if its EPD
    /// is in the book, else nil. Strips the halfmove/fullmove fields
    /// from `position.fen` before lookup.
    func lookup(_ position: Position) -> Entry? {
        let epd = Self.epd(forFEN: position.fen)
        return entries[epd]
    }

    /// Strip the last two FEN fields (halfmove clock, fullmove number)
    /// so positions match regardless of how they were reached.
    static func epd(forFEN fen: String) -> String {
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true)
        return parts.prefix(4).joined(separator: " ")
    }
}
