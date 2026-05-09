import Foundation

/// Single point of contact for every authenticated Lichess REST call the
/// app makes. The actor isolation gives us "one request at a time" for
/// free, which is what Lichess' rate-limit guidance asks for
/// (https://lichess.org/page/api-tips). All methods throw `LichessError`
/// — see that file for the full enum.
///
/// Streaming endpoints (`/api/stream/event`, `/api/board/game/stream/{id}`)
/// are **not** owned by this client; they live in the `Streams/` folder
/// and run on dedicated, long-lived URLSession tasks.
actor LichessAPIClient {

    private var token: String?
    private let urlSession: URLSession
    private let decoder: JSONDecoder

    init(token: String? = nil, urlSession: URLSession = .shared) {
        self.token = token
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
    }

    /// Replace the bearer token (after re-auth or sign-out). Pass `nil` to
    /// invalidate — subsequent authenticated calls will throw
    /// `.notAuthenticated`.
    func updateToken(_ token: String?) {
        self.token = token
    }

    // MARK: - Account

    func account() async throws -> LichessAccount {
        try await get(LichessEndpoints.account())
    }

    func accountPlaying() async throws -> [LichessPlayingGame] {
        let envelope: LichessNowPlaying = try await get(LichessEndpoints.accountPlaying())
        return envelope.nowPlaying
    }

    // MARK: - Challenges

    /// `POST /api/challenge/ai`. Returns the new game directly; caller
    /// should immediately open `/api/board/game/stream/{id}` to drive it.
    /// Lichess' AI games are always unrated, so no `rated` parameter.
    func createAIChallenge(
        level: Int,
        timeControl: LichessTimeControlSpec,
        color: LichessChallengeColor
    ) async throws -> LichessAICreatedGame {
        var params = LichessFormBody.challengeClockKeys(for: timeControl)
        params["level"] = String(max(1, min(8, level)))
        params["color"] = color.rawValue
        params["variant"] = "standard"
        return try await post(LichessEndpoints.challengeAI(), formBody: params)
    }

    /// `POST /api/challenge/{username}`. Returns the created challenge;
    /// the caller waits for the `gameStart` event on the global event-
    /// stream once the recipient accepts.
    func createUserChallenge(
        username: String,
        rated: Bool,
        timeControl: LichessTimeControlSpec,
        color: LichessChallengeColor
    ) async throws -> LichessChallenge {
        var params = LichessFormBody.challengeClockKeys(for: timeControl)
        params["rated"] = rated ? "true" : "false"
        params["color"] = color.rawValue
        params["variant"] = "standard"
        return try await post(LichessEndpoints.challengeUser(username), formBody: params)
    }

    func acceptChallenge(_ challengeID: String) async throws {
        try await postIgnoringResponse(LichessEndpoints.challengeAccept(challengeID))
    }

    func declineChallenge(
        _ challengeID: String,
        reason: LichessDeclineReason? = nil
    ) async throws {
        var params: [String: String] = [:]
        if let reason {
            params["reason"] = reason.rawValue
        }
        try await postIgnoringResponse(
            LichessEndpoints.challengeDecline(challengeID),
            formBody: params
        )
    }

    func cancelChallenge(_ challengeID: String) async throws {
        try await postIgnoringResponse(LichessEndpoints.challengeCancel(challengeID))
    }

    // MARK: - Board game actions

    func makeMove(
        gameID: String,
        uci: String,
        offerDraw: Bool = false
    ) async throws {
        try await postIgnoringResponse(
            LichessEndpoints.makeMove(gameID: gameID, uci: uci, offerDraw: offerDraw)
        )
    }

    func resign(gameID: String) async throws {
        try await postIgnoringResponse(LichessEndpoints.resign(gameID: gameID))
    }

    /// Only valid before the first move of the game. Lichess returns 400
    /// otherwise — UI should hide the action once a move has been played.
    func abort(gameID: String) async throws {
        try await postIgnoringResponse(LichessEndpoints.abort(gameID: gameID))
    }

    /// `accept = true` → offer (or accept an outstanding offer from the
    /// opponent). `accept = false` → decline an outstanding offer.
    func draw(gameID: String, accept: Bool) async throws {
        try await postIgnoringResponse(
            LichessEndpoints.draw(gameID: gameID, accept: accept)
        )
    }

    func takeback(gameID: String, accept: Bool) async throws {
        try await postIgnoringResponse(
            LichessEndpoints.takeback(gameID: gameID, accept: accept)
        )
    }

    /// Only valid after `opponentGone.claimWinInSeconds` countdown reaches
    /// zero on the game stream. Premature calls return 400.
    func claimVictory(gameID: String) async throws {
        try await postIgnoringResponse(LichessEndpoints.claimVictory(gameID: gameID))
    }

    // MARK: - Pool seek

    /// Enters the matchmaking pool with the given criteria and holds the
    /// HTTP connection open until either a partner is matched (server
    /// closes the stream) or the calling Task is cancelled (closes the
    /// stream client-side, which cancels the seek server-side).
    ///
    /// Lichess Board API restriction: the pool only accepts Rapid /
    /// Classical / Correspondence — Bullet/Blitz are blocked
    /// server-side for OAuth clients. The lobby UI hides those presets;
    /// if a caller passes one anyway the server returns 400 and we
    /// surface it via the throws.
    ///
    /// **Critical**: the actual `gameStart` event lands on
    /// `/api/stream/event` (consumed elsewhere). This call's only job is
    /// to keep the seek alive in the pool. We use a session that's NOT
    /// the shared streaming one, because the streaming session has an
    /// effectively unbounded resource timeout — perfect for game streams,
    /// but we want seeks to be cancellable at request scope, not
    /// session-wide.
    func runSeek(
        timeControl: LichessTimeControlSpec,
        rated: Bool
    ) async throws {
        guard let token else { throw LichessError.notAuthenticated }

        var request = URLRequest(url: LichessEndpoints.boardSeek())
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        var body = LichessFormBody.seekClockKeys(for: timeControl)
        body["rated"] = rated ? "true" : "false"
        body["variant"] = "standard"
        request.httpBody = LichessFormBody.encoded(body)

        let session = URLSession.lichessStreaming
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LichessError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw LichessError.tokenExpired
        case 403: throw LichessError.scopeInsufficient(scopeName: "board:play")
        case 429: throw LichessError.rateLimited(retryAfter: 60)
        case 400..<500:
            throw LichessError.clientError(status: http.statusCode, body: nil)
        default:
            throw LichessError.serverError(status: http.statusCode, body: nil)
        }

        // Drain heartbeats. The seek stays alive until the connection
        // is closed by the server (game found) or by us (Task cancelled
        // → URLSession.AsyncBytes throws CancellationError → loop exits).
        do {
            for try await _ in bytes.lines {
                if Task.isCancelled { break }
            }
        } catch is CancellationError {
            return
        } catch {
            throw LichessError.network(underlying: error)
        }
    }

    // MARK: - Internal request plumbing

    /// Builds an authenticated `URLRequest` with the bearer header. Throws
    /// `.notAuthenticated` if no token is set — exposes the missing-token
    /// case to callers loudly rather than letting them hit a 401.
    private func authenticatedRequest(for url: URL) throws -> URLRequest {
        guard let token else { throw LichessError.notAuthenticated }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let request = try authenticatedRequest(for: url)
        return try await execute(request)
    }

    private func post<T: Decodable>(
        _ url: URL,
        formBody: [String: String] = [:]
    ) async throws -> T {
        var request = try authenticatedRequest(for: url)
        request.httpMethod = "POST"
        if !formBody.isEmpty {
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = LichessFormBody.encoded(formBody)
        }
        return try await execute(request)
    }

    /// POST that doesn't care about the response body (Lichess returns
    /// `{ "ok": true }` for action endpoints). We still validate the
    /// status code so 4xx surfaces loudly.
    private func postIgnoringResponse(
        _ url: URL,
        formBody: [String: String] = [:]
    ) async throws {
        var request = try authenticatedRequest(for: url)
        request.httpMethod = "POST"
        if !formBody.isEmpty {
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = LichessFormBody.encoded(formBody)
        }
        _ = try await executeIgnoringBody(request)
    }

    /// Common code path: send the request, classify the HTTP status into
    /// either a successful decode or a typed `LichessError`.
    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await sendData(request)
        try validate(response: response, body: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LichessError.decoding(underlying: error)
        }
    }

    private func executeIgnoringBody(_ request: URLRequest) async throws {
        let (data, response) = try await sendData(request)
        try validate(response: response, body: data)
    }

    private func sendData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            throw LichessError.network(underlying: error)
        }
    }

    /// Translates HTTP status into the typed error space. Body bytes are
    /// included (decoded as UTF-8 when possible) so callers / debug
    /// surfaces have something concrete to log.
    private func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LichessError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw LichessError.tokenExpired
        case 403:
            throw LichessError.scopeInsufficient(scopeName: nil)
        case 429:
            // Lichess doesn't ship a Retry-After on 429; the API tips page
            // says wait at least 60 s.
            let suggested = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 60
            throw LichessError.rateLimited(retryAfter: suggested)
        case 400..<500:
            throw LichessError.clientError(
                status: http.statusCode,
                body: String(data: body, encoding: .utf8)
            )
        default:
            throw LichessError.serverError(
                status: http.statusCode,
                body: String(data: body, encoding: .utf8)
            )
        }
    }
}
