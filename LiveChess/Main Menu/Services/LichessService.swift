// Services/LichessService.swift
// Home-screen-specific Lichess fetcher. Owns its own REST client just
// for the endpoints the home tiles need (recent games NDJSON, daily
// puzzle JSON) — the rest of the app already routes through
// `LichessAPIClient` on `LichessSession`. The token is mirrored over
// from the session on each call so authenticated calls work as soon as
// the user signs in.

import Foundation

@MainActor
final class LichessService {

    private let apiClient = LichessHomeAPIClient()

    // MARK: - Auth

    /// Push the latest Lichess bearer token into the underlying client.
    /// Pass `nil` to clear (e.g. on sign-out).
    func authenticate(token: String?) async {
        await apiClient.setAuthToken(token)
    }

    // MARK: - Recent games

    /// Fetches the user's most recent games from
    /// `/api/games/user/{username}` (NDJSON).
    func fetchRecentGames(
        username: String,
        count: Int = 20,
        withAnalysis: Bool = false,
        withOpening: Bool = true
    ) async throws -> [LichessGame] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "max", value: String(count)),
            URLQueryItem(name: "opening", value: String(withOpening)),
            URLQueryItem(name: "clocks", value: "true"),
            URLQueryItem(name: "moves", value: "false")
        ]
        if withAnalysis {
            // `evals=true` is what actually drops the per-ply analysis
            // array into each NDJSON record. `analysis=true` is the
            // deprecated alias — keeping it for older Lichess clients
            // costs nothing. `accuracy=true` adds the summary stats
            // (which is what feeds the listing's accuracy column).
            queryItems.append(URLQueryItem(name: "evals", value: "true"))
            queryItems.append(URLQueryItem(name: "analysis", value: "true"))
            queryItems.append(URLQueryItem(name: "accuracy", value: "true"))
        }

        return try await apiClient.requestNDJSON(
            endpoint: "/api/games/user/\(username)",
            queryItems: queryItems,
            maxResults: count
        )
    }

    /// Single game with full analysis — used by the in-app review flow.
    ///
    /// Lichess exposes single-game export at `/game/export/{id}` (NOT
    /// `/api/game/{id}` — that path 200s on a slim, moves-less payload
    /// and was the reason every Review click landed on the
    /// "no recorded moves" branch). Request JSON via Accept header so
    /// we don't have to parse PGN; default Accept on that path is
    /// `application/x-chess-pgn`.
    func fetchGame(id: String) async throws -> LichessGame {
        try await apiClient.request(
            endpoint: "/game/export/\(id)",
            queryItems: [
                URLQueryItem(name: "analysis", value: "true"),
                URLQueryItem(name: "accuracy", value: "true"),
                URLQueryItem(name: "opening", value: "true"),
                URLQueryItem(name: "moves", value: "true"),
                URLQueryItem(name: "clocks", value: "true"),
                URLQueryItem(name: "evals", value: "true"),
                URLQueryItem(name: "pgnInJson", value: "false")
            ]
        )
    }

    // MARK: - Daily puzzle

    /// `/api/puzzle/daily` — public, no token required.
    /// Sending our bearer would 403 because the token lacks `puzzle:read`
    /// scope, so we explicitly skip auth on all puzzle endpoints.
    func fetchDailyPuzzle() async throws -> LichessPuzzle {
        try await apiClient.request(endpoint: "/api/puzzle/daily", skipAuth: true)
    }

    func fetchPuzzle(id: String) async throws -> LichessPuzzle {
        try await apiClient.request(endpoint: "/api/puzzle/\(id)", skipAuth: true)
    }

    /// `/api/puzzle/next` — a fresh puzzle. Called unauthenticated to
    /// avoid the 403 our `board:play` token returns on `puzzle:read`
    /// endpoints. `angle` filters by Lichess theme (e.g. "mateIn2",
    /// "endgame", "fork") so the categorised browser can ask for
    /// puzzles matching the section the user is loading more in.
    func fetchNextPuzzle(angle: String? = nil,
                         difficulty: String? = nil) async throws -> LichessPuzzle {
        var items: [URLQueryItem] = []
        if let angle {
            items.append(URLQueryItem(name: "angle", value: angle))
        }
        if let difficulty {
            items.append(URLQueryItem(name: "difficulty", value: difficulty))
        }
        return try await apiClient.request(
            endpoint: "/api/puzzle/next",
            queryItems: items.isEmpty ? nil : items,
            skipAuth: true
        )
    }
}
