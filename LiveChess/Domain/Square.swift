import Foundation

/// A chessboard square identified by a `(file, rank)` pair.
///
/// `file` runs from `0` (a-file) to `7` (h-file).
/// `rank` runs from `0` (rank 1) to `7` (rank 8).
struct Square: Hashable, Sendable, Codable, CustomStringConvertible {

    let file: Int
    let rank: Int

    init?(file: Int, rank: Int) {
        guard (0...7).contains(file), (0...7).contains(rank) else { return nil }
        self.file = file
        self.rank = rank
    }

    /// Linear index `0...63` with `a1 == 0` and `h8 == 63`.
    var index: Int { rank * 8 + file }

    init?(index: Int) {
        guard (0..<64).contains(index) else { return nil }
        self.init(file: index % 8, rank: index / 8)
    }

    init?(algebraic: String) {
        let chars = Array(algebraic)
        guard chars.count == 2 else { return nil }
        guard let fileChar = chars.first?.asciiValue,
              let rankChar = chars.last?.asciiValue else { return nil }
        let aLower = Character("a").asciiValue!
        let one = Character("1").asciiValue!
        let f = Int(fileChar) - Int(aLower)
        let r = Int(rankChar) - Int(one)
        self.init(file: f, rank: r)
    }

    var algebraic: String {
        let fileChar = Character(UnicodeScalar(UInt8(Character("a").asciiValue!) + UInt8(file)))
        let rankChar = Character(UnicodeScalar(UInt8(Character("1").asciiValue!) + UInt8(rank)))
        return "\(fileChar)\(rankChar)"
    }

    var description: String { algebraic }
}

extension Square {
    /// All 64 squares ordered by `index`.
    static let all: [Square] = (0..<64).compactMap(Square.init(index:))
}
