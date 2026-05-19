import Foundation

/// Top-level puzzle browser categories.
///
/// `rawValue` doubles as the Lichess `angle` query parameter for
/// `/api/puzzle/next` (e.g. `mateIn2`, `endgame`, `fork`). When a
/// bundled puzzle carries several themes, it is bucketed into the
/// FIRST category in `allCases` order whose `rawValue` is present
/// in its `themes` array — keeps a single puzzle from appearing in
/// multiple sections.
enum PuzzleCategory: String, CaseIterable, Sendable, Identifiable, Codable {
    case mateIn1
    case mateIn2
    case mateIn3
    case endgame
    case middlegame
    case opening
    case fork
    case pin
    case skewer
    case discoveredAttack
    case master

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mateIn1:          return "Mate in 1"
        case .mateIn2:          return "Mate in 2"
        case .mateIn3:          return "Mate in 3+"
        case .endgame:          return "Endgame"
        case .middlegame:       return "Middlegame"
        case .opening:          return "Opening"
        case .fork:             return "Tactics — Fork"
        case .pin:              return "Tactics — Pin"
        case .skewer:           return "Tactics — Skewer"
        case .discoveredAttack: return "Tactics — Discovered Attack"
        case .master:           return "Master Games"
        }
    }

    var systemImage: String {
        switch self {
        case .mateIn1:          return "crown.fill"
        case .mateIn2:          return "crown.fill"
        case .mateIn3:          return "crown"
        case .endgame:          return "flag.checkered"
        case .middlegame:       return "square.grid.3x3.fill"
        case .opening:          return "book.fill"
        case .fork:             return "arrow.triangle.branch"
        case .pin:              return "pin.fill"
        case .skewer:           return "arrow.right.to.line"
        case .discoveredAttack: return "arrow.up.left.and.arrow.down.right"
        case .master:           return "star.fill"
        }
    }

    /// Theme keys that count toward this category. Most categories
    /// map 1:1 to a Lichess theme, but "Mate in 3+" covers
    /// `mateIn3` / `mateIn4` / `mateIn5` so the section is dense
    /// enough to be worth browsing.
    var themeKeys: Set<String> {
        switch self {
        case .mateIn3: return ["mateIn3", "mateIn4", "mateIn5"]
        default:       return [rawValue]
        }
    }

    /// First category whose `themeKeys` intersect `themes`. Returns
    /// `nil` if the puzzle has none of the surfaced themes — those
    /// puzzles are silently dropped from the bundled pool.
    static func bucket(for themes: [String]) -> PuzzleCategory? {
        let set = Set(themes)
        return allCases.first { !set.isDisjoint(with: $0.themeKeys) }
    }
}
