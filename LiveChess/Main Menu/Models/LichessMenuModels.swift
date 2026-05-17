import Foundation

// MARK: - Game

// The home screen uses `LichessAccount` (defined in
// `Lichess/API/LichessModels.swift`) for the signed-in user — there's
// only one source of truth for who the user is, owned by
// `LichessSession`. The types below cover the additional shapes the
// home screen fetches itself (recent games, daily puzzle).

/// One row from `/api/games/user/{username}` (NDJSON) or `/api/game/{id}`.
///
/// The Lichess game schema is huge; we decode just the fields the home
/// screen reads. The `opponent / accuracy / result` accessors derive their
/// answer from `players` plus the requesting username.
struct LichessGame: Identifiable, Decodable, Sendable {
    let id: String
    let createdAt: TimeInterval     // ms since epoch
    let lastMoveAt: TimeInterval?   // ms since epoch
    let winner: String?             // "white" | "black" | nil = draw / aborted
    let players: GamePlayers
    let opening: GameOpening?
    let clock: GameClock?
    let moves: String?
    let speed: String?
    let status: String?

    struct GamePlayers: Decodable, Sendable {
        let white: GamePlayer
        let black: GamePlayer
    }

    struct GamePlayer: Decodable, Sendable {
        let user: GameUser?
        let analysis: GameAnalysis?
        let aiLevel: Int?
        let rating: Int?
    }

    struct GameUser: Decodable, Sendable {
        let name: String
        let id: String?
        let title: String?
    }

    struct GameAnalysis: Decodable, Sendable {
        let inaccuracy: Int?
        let mistake: Int?
        let blunder: Int?
        let acpl: Int?
        let accuracy: Double?
    }

    // MARK: Derived

    var date: Date {
        // Prefer last-move time if present; otherwise createdAt.
        Date(timeIntervalSince1970: (lastMoveAt ?? createdAt) / 1000)
    }

    var moveCount: Int {
        guard let moves, !moves.isEmpty else { return 0 }
        return moves.split(separator: " ").count
    }

    private func sideMatches(_ name: String?, _ username: String) -> Bool {
        guard let name else { return false }
        return name.caseInsensitiveCompare(username) == .orderedSame
    }

    private func myColor(for username: String) -> String? {
        if sideMatches(players.white.user?.name, username) { return "white" }
        if sideMatches(players.black.user?.name, username) { return "black" }
        return nil
    }

    func opponent(for username: String) -> String {
        if sideMatches(players.white.user?.name, username) {
            return players.black.user?.name
                ?? players.black.aiLevel.map { "Stockfish lvl \($0)" }
                ?? "Anonymous"
        }
        return players.white.user?.name
            ?? players.white.aiLevel.map { "Stockfish lvl \($0)" }
            ?? "Anonymous"
    }

    func accuracy(for username: String) -> Double? {
        switch myColor(for: username) {
        case "white": return players.white.analysis?.accuracy
        case "black": return players.black.analysis?.accuracy
        default:      return nil
        }
    }

    func result(for username: String) -> GameResult {
        guard let winner else { return .draw }
        guard let myColor = myColor(for: username) else { return .draw }
        return myColor == winner ? .win : .loss
    }
}

struct GameOpening: Decodable, Sendable {
    let name: String?
    let eco: String?
    let ply: Int?
}

struct GameClock: Decodable, Sendable {
    let initial: Int?     // seconds
    let increment: Int?   // seconds

    /// Compact time-control display, e.g. "10+0" / "3+2".
    var displayString: String {
        let minutes = (initial ?? 0) / 60
        return "\(minutes)+\(increment ?? 0)"
    }
}

// MARK: - Result

enum GameResult: Sendable {
    case win
    case loss
    case draw

    var shortLabel: String {
        switch self {
        case .win:  "W"
        case .loss: "L"
        case .draw: "D"
        }
    }
}

// MARK: - Puzzle

/// Response shape for `/api/puzzle/daily` and `/api/puzzle/{id}`.
struct LichessPuzzle: Decodable, Sendable {
    let puzzle: PuzzleInfo

    struct PuzzleInfo: Decodable, Sendable {
        let id: String
        let rating: Int?
        let themes: [String]
        let plays: Int?
        let solution: [String]?
        let initialPly: Int?
        let fen: String?           // FEN of the puzzle starting position
        let lastMove: String?      // UCI of the opponent's last move
    }
}
