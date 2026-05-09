import Foundation

/// Long-lived subscription to Lichess' global event stream
/// (`/api/stream/event`) — the channel that pushes `gameStart`,
/// `gameFinish`, `challenge`, `challengeCanceled`, `challengeDeclined`
/// to the logged-in user.
///
/// Lifecycle: `start()` opens the HTTP connection and begins yielding
/// onto the `events` AsyncStream; `stop()` cancels the underlying URL
/// task and ends the stream. The actor reconnects automatically on
/// network drops with exponential backoff (1 → 2 → 4 → … → 30 s cap).
///
/// **Reconnect caveat**: Lichess does NOT replay missed events on
/// reconnect. The lobby controller compensates by calling
/// `LichessAPIClient.accountPlaying()` after a reconnect to discover any
/// games that started while we were offline.
///
/// Lichess restricts each token to one event stream globally — if the
/// app opens a second one, the first server-side connection is closed.
/// Construct a single instance per signed-in session.
actor LichessEventStream {

    /// AsyncStream consumers iterate to receive events. Yielded only when
    /// `start()` has been called and the connection is live.
    nonisolated let events: AsyncStream<LichessEvent>

    private let continuation: AsyncStream<LichessEvent>.Continuation
    private var token: String
    private let urlSession: URLSession
    private var loop: Task<Void, Never>?

    init(
        token: String,
        urlSession: URLSession = .lichessStreaming
    ) {
        self.token = token
        self.urlSession = urlSession
        var continuationOut: AsyncStream<LichessEvent>.Continuation!
        self.events = AsyncStream { continuationOut = $0 }
        self.continuation = continuationOut
    }

    /// Idempotent — calling `start()` twice has no effect after the first.
    /// Boots the reconnect loop on the actor's executor; control returns
    /// immediately. Cancellation happens via `stop()` or actor deinit.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Tears down the connection and finalises the events stream so any
    /// `for await` loops on it terminate cleanly. Idempotent.
    func stop() {
        loop?.cancel()
        loop = nil
        continuation.finish()
    }

    /// Replace the bearer token (after re-auth). The new token applies on
    /// the next reconnect; in-flight connection is left as-is and will
    /// switch over when it next drops.
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
                // Clean EOF (server closed) — reset backoff and reconnect.
                backoffSeconds = 1
            } catch is CancellationError {
                return
            } catch {
                // Network failure / server error / decode breakage on the
                // wire. Exponential backoff capped at 30 s. We don't
                // surface the error onto the events stream — the UI
                // observes connection state separately and the events
                // stream only carries successfully-decoded events.
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 30)
            }
        }
    }

    private func connectAndPump() async throws {
        var request = URLRequest(url: LichessEndpoints.streamEvents())
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await urlSession.bytes(for: request)
        try validate(response: response)

        for try await event in NDJSON.stream(from: bytes, as: LichessEvent.self) {
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
        case 429: throw LichessError.rateLimited(retryAfter: 60)
        case 400..<500: throw LichessError.clientError(status: http.statusCode, body: nil)
        default: throw LichessError.serverError(status: http.statusCode, body: nil)
        }
    }
}
