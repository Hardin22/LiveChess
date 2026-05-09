import Foundation

/// Long-lived subscription to a single Board API game stream
/// (`/api/board/game/stream/{id}`). Pushes `gameFull` (initial frame +
/// re-emitted on reconnect), `gameState` (per-tick deltas with full
/// move list, clocks, draw/takeback flags, status), `chatLine`, and
/// `opponentGone` events.
///
/// Lifecycle mirrors `LichessEventStream`: `start()` boots the
/// reconnect loop, `stop()` tears down. The reconnect strategy here is
/// the same exponential 1 → 30 s backoff — but reconnect IS safe for
/// state because Lichess re-emits the entire `gameFull` frame on a
/// fresh connection. The match session treats the first event after a
/// reconnect as authoritative and replays moves from scratch.
///
/// Each game session creates its own instance; multiple game streams
/// can run in parallel against the same token (Lichess only restricts
/// the GLOBAL event stream to one per token, not per-game streams).
actor LichessGameStream {

    nonisolated let updates: AsyncStream<LichessGameStreamEvent>

    private let continuation: AsyncStream<LichessGameStreamEvent>.Continuation
    private let gameID: String
    private var token: String
    private let urlSession: URLSession
    private var loop: Task<Void, Never>?

    init(
        gameID: String,
        token: String,
        urlSession: URLSession = .lichessStreaming
    ) {
        self.gameID = gameID
        self.token = token
        self.urlSession = urlSession
        var continuationOut: AsyncStream<LichessGameStreamEvent>.Continuation!
        self.updates = AsyncStream { continuationOut = $0 }
        self.continuation = continuationOut
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        continuation.finish()
    }

    func updateToken(_ token: String) {
        self.token = token
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    // MARK: - Private

    private func runReconnectLoop() async {
        var backoffSeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try await connectAndPump()
                backoffSeconds = 1
            } catch is CancellationError {
                return
            } catch LichessError.clientError(let status, _) where status == 404 {
                // Game no longer exists — server-side cancelled / cleanup.
                // Don't keep retrying; finalise the stream and let the
                // session decide what to surface to the user.
                continuation.finish()
                return
            } catch {
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 30)
            }
        }
    }

    private func connectAndPump() async throws {
        var request = URLRequest(url: LichessEndpoints.streamGame(gameID))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await urlSession.bytes(for: request)
        try validate(response: response)

        for try await event in NDJSON.stream(from: bytes, as: LichessGameStreamEvent.self) {
            if Task.isCancelled { return }
            continuation.yield(event)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LichessError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw LichessError.tokenExpired
        case 403: throw LichessError.scopeInsufficient(scopeName: "board:play")
        case 404: throw LichessError.clientError(status: 404, body: nil)
        case 429: throw LichessError.rateLimited(retryAfter: 60)
        case 400..<500: throw LichessError.clientError(status: http.statusCode, body: nil)
        default: throw LichessError.serverError(status: http.statusCode, body: nil)
        }
    }
}
