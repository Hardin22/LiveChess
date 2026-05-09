import Foundation

// MARK: - Account

/// Subset of Lichess' `UserExtended` schema (`/api/account`) we actually
/// consume in the lobby and HUD. Lichess returns far more (counts,
/// playTime, profile blob, etc.) — we ignore everything else by virtue of
/// `Decodable` skipping unknown keys.
struct LichessAccount: Sendable, Decodable, Equatable {
    let id: String
    let username: String
    let title: String?              // GM, IM, FM, etc. — nil for untitled
    let perfs: [String: LichessPerf]?

    /// Quick rating fetch for a given speed; falls back to nil if the user
    /// has never played that variant.
    func rating(forPerfKey key: String) -> Int? {
        perfs?[key]?.rating
    }
}

/// Per-perf rating block (one entry per speed/variant: `bullet`, `blitz`,
/// `rapid`, `classical`, `correspondence`, `chess960`, ...).
struct LichessPerf: Sendable, Decodable, Equatable {
    let games: Int
    let rating: Int
    let rd: Int                     // rating deviation
    let prog: Int                   // recent progress
    let prov: Bool?                 // true = provisional rating

    var isProvisional: Bool { prov ?? false }
}

// MARK: - Active games

/// Wrapper for the `/api/account/playing` response.
struct LichessNowPlaying: Sendable, Decodable, Equatable {
    let nowPlaying: [LichessPlayingGame]
}

/// One in-progress game from the active-games list.
struct LichessPlayingGame: Sendable, Decodable, Equatable {
    let gameId: String
    let fullId: String
    let color: LichessColor
    let fen: String
    let hasMoved: Bool
    let isMyTurn: Bool
    let lastMove: String?
    let opponent: LichessOpponent
    let perf: String                // speed key, e.g. "rapid"
    let rated: Bool
    let secondsLeft: Int?
    let source: String?             // "lobby", "friend", "ai", ...
    let speed: String               // "rapid", "blitz", ...
    let variant: LichessVariant
}

struct LichessOpponent: Sendable, Decodable, Equatable {
    let id: String?
    let username: String
    let rating: Int?
    let ratingDiff: Int?
    let title: String?
    let aiLevel: Int?               // present iff opponent is Stockfish-on-Lichess
}

// MARK: - Challenge

/// `/api/challenge/{username}` response and the payload of `challenge`
/// events on the event stream. We model only the fields we display or
/// branch on.
struct LichessChallenge: Sendable, Decodable, Equatable {
    let id: String
    let url: String?
    let status: String              // "created", "accepted", "declined", "canceled"
    let challenger: LichessChallengePlayer?
    let destUser: LichessChallengePlayer?
    let variant: LichessVariant
    let rated: Bool
    let speed: String               // "blitz", "rapid", ...
    let timeControl: LichessTimeControl
    let color: String               // "white" | "black" | "random"
    let finalColor: LichessColor?   // resolved colour after random
    let perf: LichessChallengePerf
    let direction: String?          // "in" / "out" on event-stream payloads
    let declineReason: String?      // present on decline event
    let declineReasonKey: String?
}

struct LichessChallengePlayer: Sendable, Decodable, Equatable {
    let id: String?
    let name: String?
    let title: String?
    let rating: Int?
    let provisional: Bool?
    let online: Bool?
}

struct LichessChallengePerf: Sendable, Decodable, Equatable {
    let icon: String?
    let name: String
}

struct LichessTimeControl: Sendable, Decodable, Equatable {
    let type: String                // "clock" | "correspondence" | "unlimited"
    let limit: Int?                 // seconds, only for clock
    let increment: Int?             // seconds, only for clock
    let show: String?               // human-readable, e.g. "10+0"
    let daysPerTurn: Int?           // only for correspondence
}

// MARK: - AI challenge response

/// `POST /api/challenge/ai` returns this directly — *not* a `Challenge`
/// envelope, because the game starts immediately.
struct LichessAICreatedGame: Sendable, Decodable, Equatable {
    let id: String
    let rated: Bool
    let speed: String
    let perf: String
    let createdAt: Int64?
    let fullId: String?
    let player: String?             // "white" | "black"
    let status: String?
    let variant: LichessVariant
    let fen: String?
    let turns: Int?
    let source: String?
}

// MARK: - Event stream (`/api/stream/event`)

/// Sum of every event the global event-stream emits. We decode the
/// `type` discriminator and dispatch to the typed payload. Unknown event
/// types decode into `.unknown` so a future Lichess addition doesn't
/// crash the parser.
enum LichessEvent: Sendable, Equatable {
    case gameStart(LichessGameEventInfo)
    case gameFinish(LichessGameEventInfo)
    case challenge(LichessChallenge)
    case challengeCanceled(LichessChallenge)
    case challengeDeclined(LichessChallenge)
    case unknown(type: String)
}

extension LichessEvent: Decodable {
    private enum CodingKeys: String, CodingKey { case type, game, challenge }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "gameStart":
            self = .gameStart(try c.decode(LichessGameEventInfo.self, forKey: .game))
        case "gameFinish":
            self = .gameFinish(try c.decode(LichessGameEventInfo.self, forKey: .game))
        case "challenge":
            self = .challenge(try c.decode(LichessChallenge.self, forKey: .challenge))
        case "challengeCanceled":
            self = .challengeCanceled(try c.decode(LichessChallenge.self, forKey: .challenge))
        case "challengeDeclined":
            self = .challengeDeclined(try c.decode(LichessChallenge.self, forKey: .challenge))
        default:
            self = .unknown(type: type)
        }
    }
}

/// `GameEventInfo` payload (gameStart, gameFinish). `ratingDiff` is the
/// signed Elo delta — only present on `gameFinish` for rated games.
struct LichessGameEventInfo: Sendable, Decodable, Equatable {
    let gameId: String
    let fullId: String
    let id: String?
    let fen: String?
    let color: LichessColor
    let lastMove: String?
    let source: String?
    let status: LichessStatus?
    let variant: LichessVariant
    let speed: String
    let perf: String
    let rating: Int?
    let rated: Bool
    let hasMoved: Bool?
    let opponent: LichessOpponent
    let isMyTurn: Bool?
    let secondsLeft: Int?
    let winner: LichessColor?
    let ratingDiff: Int?
    let tournamentId: String?
}

// MARK: - Game stream (`/api/board/game/stream/{id}`)

/// Sum of every event a single-game stream emits. `gameFull` is always the
/// first; subsequent events are `gameState`, `chatLine`, `opponentGone`,
/// or unknown future types.
enum LichessGameStreamEvent: Sendable, Equatable {
    case gameFull(LichessGameFull)
    case gameState(LichessGameState)
    case chatLine(LichessChatLine)
    case opponentGone(LichessOpponentGone)
    case unknown(type: String)
}

extension LichessGameStreamEvent: Decodable {
    private enum DiscriminatorKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try probe.decode(String.self, forKey: .type)
        switch type {
        case "gameFull":
            self = .gameFull(try LichessGameFull(from: decoder))
        case "gameState":
            self = .gameState(try LichessGameState(from: decoder))
        case "chatLine":
            self = .chatLine(try LichessChatLine(from: decoder))
        case "opponentGone":
            self = .opponentGone(try LichessOpponentGone(from: decoder))
        default:
            self = .unknown(type: type)
        }
    }
}

/// First frame of `/api/board/game/stream/{id}` and re-emitted on
/// reconnection. Carries the entire game's static info plus the *current*
/// `state` snapshot — clients can rebuild from this without history.
struct LichessGameFull: Sendable, Decodable, Equatable {
    let id: String
    let variant: LichessVariant
    let clock: LichessClockInit?    // nil for unlimited / correspondence
    let speed: String
    let perf: LichessGamePerf?
    let rated: Bool
    let createdAt: Int64
    let white: LichessGamePlayer
    let black: LichessGamePlayer
    let initialFen: String          // "startpos" or a FEN
    let state: LichessGameState
    let daysPerTurn: Int?
    let tournamentId: String?
}

struct LichessClockInit: Sendable, Decodable, Equatable {
    let initial: Int                // ms
    let increment: Int              // ms
}

struct LichessGamePerf: Sendable, Decodable, Equatable {
    let name: String
}

struct LichessGamePlayer: Sendable, Decodable, Equatable {
    let id: String?
    let name: String?
    let title: String?
    let rating: Int?
    let provisional: Bool?
    let aiLevel: Int?
    let user: LichessGameUser?       // sometimes nested for human players
}

struct LichessGameUser: Sendable, Decodable, Equatable {
    let id: String?
    let name: String?
    let title: String?
}

/// Per-tick state update. `moves` is a SPACE-separated list of UCI moves
/// played so far across the whole game; clients diff against the previous
/// frame to find new moves. Clocks are in *milliseconds*.
struct LichessGameState: Sendable, Decodable, Equatable {
    let type: String?               // "gameState" on stream frames
    let moves: String               // "e2e4 e7e5 g1f3 ..."
    let wtime: Int                  // ms remaining for white
    let btime: Int                  // ms remaining for black
    let winc: Int                   // ms increment per move for white
    let binc: Int                   // ms increment per move for black
    let status: LichessStatus
    let winner: LichessColor?
    let wdraw: Bool?
    let bdraw: Bool?
    let wtakeback: Bool?
    let btakeback: Bool?
    let rematch: String?            // gameId of the rematch, when applicable
}

struct LichessChatLine: Sendable, Decodable, Equatable {
    let type: String?               // "chatLine"
    let username: String
    let text: String
    let room: String                // "player" | "spectator"
}

struct LichessOpponentGone: Sendable, Decodable, Equatable {
    let type: String?               // "opponentGone"
    let gone: Bool
    /// Seconds remaining until claim-victory becomes available. nil if
    /// `gone == false` or the opponent just reconnected.
    let claimWinInSeconds: Int?
}

// MARK: - Shared primitives

enum LichessColor: String, Sendable, Decodable, Equatable {
    case white, black
}

struct LichessVariant: Sendable, Decodable, Equatable {
    let key: String                 // "standard", "chess960", "crazyhouse", ...
    let name: String?
    let short: String?
}

/// Game status as Lichess models it. Decodes from either the integer code
/// (10/20/25/...) or the string label (`mate`, `resign`, ...). Lichess
/// uses the string form across the Board API and event stream.
enum LichessStatus: String, Sendable, Decodable, Equatable {
    case created
    case started
    case aborted
    case mate
    case resign
    case stalemate
    case timeout
    case draw
    case outoftime
    case cheat
    case noStart
    case unknownFinish
    case variantEnd

    /// True for any state where the game is no longer in progress.
    var isFinished: Bool {
        switch self {
        case .created, .started: return false
        default: return true
        }
    }
}

// MARK: - Match request types (outbound — used to build POST bodies)

/// Time-control selection for outbound seek / challenge requests. The
/// REST layer translates this to either `clock.limit` + `clock.increment`
/// (real-time) or `days` (correspondence) form-body params, or omits both
/// for unlimited.
enum LichessTimeControlSpec: Sendable, Hashable {
    /// Real-time game with `limit` seconds base + `increment` seconds Fischer.
    case realTime(limitSeconds: Int, incrementSeconds: Int)
    /// Correspondence game with `daysPerTurn` ∈ {1, 2, 3, 5, 7, 10, 14}.
    case correspondence(daysPerTurn: Int)
    /// No clock — only valid for direct challenges.
    case unlimited

    /// Lichess' `Speed` bucket for this control, used to display the
    /// right icon and to enforce Board-API restrictions client-side
    /// (Bullet/Blitz aren't allowed in `/api/board/seek`).
    var speed: LichessSpeed {
        switch self {
        case .unlimited:
            return .correspondence
        case .correspondence:
            return .correspondence
        case let .realTime(limit, increment):
            // Lichess bucketing: `total = limit + 40 * increment` seconds.
            let total = limit + 40 * increment
            switch total {
            case ..<30: return .ultraBullet
            case 30..<180: return .bullet
            case 180..<480: return .blitz
            case 480..<1500: return .rapid
            default: return .classical
            }
        }
    }
}

enum LichessSpeed: String, Sendable, Hashable {
    case ultraBullet
    case bullet
    case blitz
    case rapid
    case classical
    case correspondence
}

/// Side preference when issuing a challenge / seek. `random` is what most
/// players pick, but `white`/`black` is allowed for friend challenges.
enum LichessChallengeColor: String, Sendable, Hashable {
    case random
    case white
    case black
}

/// Reason payload for `POST /api/challenge/{id}/decline`. Lichess
/// validates this against a fixed list — anything else returns 400.
enum LichessDeclineReason: String, Sendable, Hashable {
    case generic
    case later
    case tooFast
    case tooSlow
    case timeControl
    case rated
    case casual
    case standard
    case variant
    case noBot
    case onlyBot
}
