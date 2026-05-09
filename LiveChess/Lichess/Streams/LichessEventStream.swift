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

    /// Fired when Lichess returns 401 — the bearer is no longer valid.
    /// Owners (the lobby controller / session) should drop the token
    /// and surface the sign-in CTA. Loop exits after firing; no
    /// further reconnect attempts.
    var onAuthFailure: (@Sendable () async -> Void)?

    /// Fired after a successful re-connect (i.e. the second-or-later
    /// time the loop opens an HTTP connection). Owners use this to
    /// re-fetch state that the event stream doesn't replay across the
    /// gap (e.g. `/api/account/playing` for games that started while
    /// we were offline).
    var onReconnect: (@Sendable () async -> Void)?

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

    /// Setter for the reconnect callback. Must go through a method
    /// because `var` properties on an actor can't be assigned from
    /// outside without hopping through one.
    func setReconnectHandler(_ handler: @escaping @Sendable () async -> Void) {
        self.onReconnect = handler
    }

    func setAuthFailureHandler(_ handler: @escaping @Sendable () async -> Void) {
        self.onAuthFailure = handler
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    // MARK: - Private

    private func runReconnectLoop() async {
        var backoffSeconds: UInt64 = 1
        var hasConnectedBefore = false
        while !Task.isCancelled {
            do {
                try await connectAndPump()
                // Clean EOF (server closed) — reset backoff and reconnect.
                // After the FIRST successful pump-then-disconnect we
                // count subsequent connects as "reconnects" so owners
                // can re-fetch missed state on the next iteration.
                hasConnectedBefore = true
                backoffSeconds = 1
            } catch is CancellationError {
                return
            } catch LichessError.tokenExpired {
                // Bearer is dead — no point retrying. Surface upward
                // and exit; the session layer will wipe the keychain
                // and prompt re-auth.
                await onAuthFailure?()
                return
            } catch {
                // Network failure / 5xx / decode breakage on the wire.
                // Exponential backoff capped at 30 s. We don't surface
                // transient errors on the events stream — the UI
                // observes connection state separately.
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 30)
            }
            // If we get here on the second-or-later iteration, the next
            // connectAndPump call will be a *re*-connect from the
            // owner's perspective. Notify so they can re-fetch state
            // that wasn't replayed across the gap (e.g. account/playing).
            if hasConnectedBefore && !Task.isCancelled {
                await onReconnect?()
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
