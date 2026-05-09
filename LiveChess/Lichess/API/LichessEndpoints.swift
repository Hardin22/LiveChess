import Foundation

/// Centralised URL builders for every Lichess endpoint LiveChess talks
/// to. Keeping them out of the API client makes the client easier to
/// test (you can swap the base URL for a stub server without rewriting
/// path strings) and gives a single place to audit coverage against the
/// Lichess OpenAPI spec.
enum LichessEndpoints {

    /// Production base URL. Lichess also exposes `https://lichess.dev`
    /// as a sandbox but it shares the production database, so it doesn't
    /// help for testing — we just point at lichess.org.
    static let baseURL = URL(string: "https://lichess.org")!

    // MARK: - Account

    static func account() -> URL { baseURL.appendingPathComponent("/api/account") }
    static func accountPlaying() -> URL {
        baseURL.appendingPathComponent("/api/account/playing")
    }

    // MARK: - Streams

    static func streamEvents() -> URL {
        baseURL.appendingPathComponent("/api/stream/event")
    }

    static func streamGame(_ gameID: String) -> URL {
        baseURL.appendingPathComponent("/api/board/game/stream/\(gameID)")
    }

    static func boardSeek() -> URL {
        baseURL.appendingPathComponent("/api/board/seek")
    }

    // MARK: - Board game actions

    static func makeMove(gameID: String, uci: String, offerDraw: Bool) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/board/game/\(gameID)/move/\(uci)"),
            resolvingAgainstBaseURL: false
        )!
        if offerDraw {
            components.queryItems = [URLQueryItem(name: "offeringDraw", value: "true")]
        }
        return components.url!
    }

    static func resign(gameID: String) -> URL {
        baseURL.appendingPathComponent("/api/board/game/\(gameID)/resign")
    }

    static func abort(gameID: String) -> URL {
        baseURL.appendingPathComponent("/api/board/game/\(gameID)/abort")
    }

    /// `accept = true` → offer-or-accept (`/draw/yes`).
    /// `accept = false` → decline (`/draw/no`).
    static func draw(gameID: String, accept: Bool) -> URL {
        baseURL.appendingPathComponent(
            "/api/board/game/\(gameID)/draw/\(accept ? "yes" : "no")"
        )
    }

    /// Same yes/no semantics as `draw(...)`.
    static func takeback(gameID: String, accept: Bool) -> URL {
        baseURL.appendingPathComponent(
            "/api/board/game/\(gameID)/takeback/\(accept ? "yes" : "no")"
        )
    }

    static func claimVictory(gameID: String) -> URL {
        baseURL.appendingPathComponent("/api/board/game/\(gameID)/claim-victory")
    }

    static func claimDraw(gameID: String) -> URL {
        baseURL.appendingPathComponent("/api/board/game/\(gameID)/claim-draw")
    }

    // MARK: - Challenge

    static func challengeAI() -> URL {
        baseURL.appendingPathComponent("/api/challenge/ai")
    }

    static func challengeUser(_ username: String) -> URL {
        baseURL.appendingPathComponent("/api/challenge/\(username)")
    }

    static func challengeAccept(_ challengeID: String) -> URL {
        baseURL.appendingPathComponent("/api/challenge/\(challengeID)/accept")
    }

    static func challengeDecline(_ challengeID: String) -> URL {
        baseURL.appendingPathComponent("/api/challenge/\(challengeID)/decline")
    }

    static func challengeCancel(_ challengeID: String) -> URL {
        baseURL.appendingPathComponent("/api/challenge/\(challengeID)/cancel")
    }
}

/// Builds an `application/x-www-form-urlencoded` body string from a
/// dictionary of params. Used by every POST endpoint. We delegate to
/// `URLComponents.percentEncodedQuery` to get the canonical encoding
/// (`+` for space, percent-encoded reserveds).
enum LichessFormBody {
    static func encoded(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    /// Convenience: encodes a `LichessTimeControlSpec` into the right body
    /// keys for `/api/challenge/{user}` and `/api/board/seek`.
    /// `clock.limit` is in **seconds** for challenges; `time` is in
    /// **minutes** for seeks. Caller picks the matching key set.
    static func challengeClockKeys(
        for spec: LichessTimeControlSpec
    ) -> [String: String] {
        switch spec {
        case let .realTime(limitSeconds, incrementSeconds):
            return [
                "clock.limit": String(limitSeconds),
                "clock.increment": String(incrementSeconds),
            ]
        case let .correspondence(daysPerTurn):
            return ["days": String(daysPerTurn)]
        case .unlimited:
            return [:]
        }
    }

    /// Same conversion targeted at the `/api/board/seek` form, which
    /// uses `time` (minutes) and `increment` (seconds) for real-time and
    /// `days` for correspondence.
    static func seekClockKeys(
        for spec: LichessTimeControlSpec
    ) -> [String: String] {
        switch spec {
        case let .realTime(limitSeconds, incrementSeconds):
            return [
                "time": String(Double(limitSeconds) / 60.0),
                "increment": String(incrementSeconds),
            ]
        case let .correspondence(daysPerTurn):
            return ["days": String(daysPerTurn)]
        case .unlimited:
            // Pool seeks don't accept unlimited; caller should validate
            // before reaching this branch. We return empty so the server
            // returns a 400 if it slips through, rather than silently
            // converting to "real-time at 0+0".
            return [:]
        }
    }
}
