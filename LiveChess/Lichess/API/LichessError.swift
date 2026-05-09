import Foundation

/// Single error type for everything the Lichess REST + streaming layer can
/// emit. Designed so callers can switch on the case to drive UI feedback
/// (sign-out on `tokenExpired`, toast on `rateLimited`, etc.) without
/// having to peek at HTTP status codes themselves.
enum LichessError: Error, Sendable {
    /// Caller invoked an authenticated endpoint without a token in hand.
    /// Different from `tokenExpired` — this is a *programming* error
    /// (the auth flow wasn't run yet), whereas `tokenExpired` is a
    /// runtime token-rotation event.
    case notAuthenticated

    /// Server returned 401 — bearer token is no longer valid. The session
    /// layer wipes it from the keychain and shows the sign-in CTA.
    case tokenExpired

    /// Server returned 403 — the token is valid but doesn't carry the
    /// scope this endpoint requires. The associated value is the
    /// human-readable scope name (e.g. `"board:play"`) when we can derive
    /// it; nil otherwise.
    case scopeInsufficient(scopeName: String?)

    /// Server returned 429 — we hit a rate limit. Per Lichess' API tips
    /// the right behaviour is to wait at least 60 s and retry, single-
    /// threaded. The associated value is the suggested back-off in
    /// seconds.
    case rateLimited(retryAfter: TimeInterval)

    /// 4xx other than 401/403/429.
    case clientError(status: Int, body: String?)

    /// 5xx response — usually transient. Stream layers retry; one-shot
    /// REST callers may want to surface a "Lichess is having a moment"
    /// toast.
    case serverError(status: Int, body: String?)

    /// JSONDecoder failed on a payload we expected to be well-formed.
    /// Either Lichess changed shape (rare but possible) or our model is
    /// wrong.
    case decoding(underlying: any Error)

    /// URLSession-level failure (DNS, TLS, connectivity dropped). Stream
    /// layers reconnect with backoff; REST callers surface to UI.
    case network(underlying: any Error)

    /// Response body wasn't an `HTTPURLResponse` or some other invariant
    /// the URL loading system normally guarantees broke. Should be
    /// effectively impossible.
    case invalidResponse
}

extension LichessError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notAuthenticated:
            return "LichessError.notAuthenticated"
        case .tokenExpired:
            return "LichessError.tokenExpired"
        case .scopeInsufficient(let scope):
            return "LichessError.scopeInsufficient(\(scope ?? "?"))"
        case .rateLimited(let retry):
            return "LichessError.rateLimited(retryAfter: \(retry)s)"
        case .clientError(let status, let body):
            return "LichessError.clientError(\(status), body: \(body ?? "nil"))"
        case .serverError(let status, let body):
            return "LichessError.serverError(\(status), body: \(body ?? "nil"))"
        case .decoding(let error):
            return "LichessError.decoding(\(error))"
        case .network(let error):
            return "LichessError.network(\(error))"
        case .invalidResponse:
            return "LichessError.invalidResponse"
        }
    }
}
