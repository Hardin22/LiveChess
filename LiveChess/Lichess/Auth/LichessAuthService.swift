import Foundation
import AuthenticationServices
import UIKit

/// Drives the OAuth 2.0 PKCE handshake with Lichess and persists the
/// resulting bearer token via the keychain store.
///
/// Lichess' OAuth implementation
/// (https://lichess.org/api#section/Authentication) is a public-client PKCE
/// flow — no app pre-registration, no client secret. The shape:
///
///   1. Build an `https://lichess.org/oauth` authorize URL with our chosen
///      `client_id`, `redirect_uri`, the SHA-256 `code_challenge`, the
///      requested `scope`, and a random `state`.
///   2. Hand it to `ASWebAuthenticationSession`, which opens the system
///      web view, lets the user log in + consent, and intercepts the
///      `livechess://oauth/callback` redirect on our behalf.
///   3. Parse `code` + `state` from the callback URL; abort if `state`
///      doesn't match what we sent (CSRF defence per RFC 6749 §10.12).
///   4. POST `https://lichess.org/api/token` with `grant_type=authorization_code`
///      + the `code_verifier` to swap the code for an access token.
///   5. Wrap the response in `StoredToken` and return.
///
/// `signOut(token:)` issues `DELETE /api/token` so the server-side bearer
/// also goes away. The keychain wipe is the caller's responsibility.
@MainActor
final class LichessAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum AuthError: Error, Equatable, Sendable {
        /// The user dismissed the system auth sheet without completing.
        case userCancelled
        /// The redirect URL came back without query items / scheme we expected.
        case malformedCallback
        /// `state` round-tripped from the redirect didn't match what we sent.
        /// Treated as fatal — we abort the flow rather than trade the code.
        case stateMismatch
        /// Callback included `error=...` instead of `code` (e.g. user denied
        /// consent at the Lichess page).
        case authorizationDenied(String)
        /// `code` query item was missing or empty.
        case missingCode
        /// `POST /api/token` returned non-2xx. The body, if decodable as
        /// UTF-8, is included for diagnostics.
        case tokenExchangeFailed(httpStatus: Int, body: String?)
    }

    nonisolated static let defaultClientID = "app.livechess.visionos"
    nonisolated static let defaultRedirectURI = "livechess://oauth/callback"
    /// Minimum scopes for v1: play games, send/accept challenges, read the
    /// account's preferences (board orientation, autoQueen, etc.). Email
    /// scope is intentionally omitted to keep the consent screen short.
    nonisolated static let defaultScope = "board:play challenge:write preference:read"

    private let clientID: String
    private let redirectURI: String
    private let scope: String
    private let urlSession: URLSession

    init(
        clientID: String = LichessAuthService.defaultClientID,
        redirectURI: String = LichessAuthService.defaultRedirectURI,
        scope: String = LichessAuthService.defaultScope,
        urlSession: URLSession = .shared
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.urlSession = urlSession
        super.init()
    }

    /// Drives the full PKCE round-trip end-to-end and returns a freshly
    /// minted `StoredToken`. The caller saves it to the keychain.
    func signIn() async throws -> StoredToken {
        let verifier = PKCE.generateCodeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = PKCE.generateState()

        let authorizationURL = try buildAuthorizationURL(
            challenge: challenge,
            state: state
        )
        let callback = try await presentWebAuthSession(authorizationURL: authorizationURL)
        let code = try parseCallback(callback, expectedState: state)
        return try await exchangeCodeForToken(code, verifier: verifier)
    }

    /// Best-effort revoke: tells Lichess the token is no longer wanted. We
    /// don't surface non-2xx as an error because the token might already be
    /// expired or revoked server-side — for a logout flow, that's success.
    func signOut(token: String) async throws {
        var request = URLRequest(url: URL(string: "https://lichess.org/api/token")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await urlSession.data(for: request)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        // visionOS: any active key window is fine — the system auth view
        // pops out as a separate window/sheet anyway. We hop to main only
        // to read `UIApplication.shared`, which is `@MainActor` isolated.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive }
                ?? scenes.first
            // Sign-in is only ever invoked from a tap inside the lobby
            // window, so there's always at least one foreground scene with
            // a key window by this point. The fallback path below builds a
            // detached anchor on the scene if no window has been
            // materialised yet — keeps the protocol contract
            // (non-optional return) safe under unexpected timing.
            guard let scene else {
                preconditionFailure(
                    "ASWebAuthenticationSession presented with no active UIWindowScene"
                )
            }
            return scene.windows.first(where: \.isKeyWindow)
                ?? scene.windows.first
                ?? UIWindow(windowScene: scene)
        }
    }

    // MARK: - Private

    private func buildAuthorizationURL(challenge: String, state: String) throws -> URL {
        var components = URLComponents(string: "https://lichess.org/oauth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw AuthError.malformedCallback  // unreachable in practice
        }
        return url
    }

    private func presentWebAuthSession(authorizationURL: URL) async throws -> URL {
        // `callbackURLScheme:` strips the `://path` part — pass just the
        // scheme name. ASWebAuthenticationSession matches case-insensitively
        // and dismisses its sheet automatically when the system sees a URL
        // beginning with that scheme.
        let scheme = URL(string: redirectURI)?.scheme ?? "livechess"

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: AuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.malformedCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Reuse the system browser cookies if the user is already signed
            // in to lichess.org — turns the consent into a single tap. The
            // OAuth code itself is short-lived and bound to our PKCE
            // verifier, so cookie reuse doesn't expose us.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func parseCallback(_ url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthError.malformedCallback
        }
        let items = components.queryItems ?? []
        let dict = Dictionary(items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })

        if let error = dict["error"], !error.isEmpty {
            let description = dict["error_description"] ?? error
            throw AuthError.authorizationDenied(description)
        }
        guard let returnedState = dict["state"], returnedState == expectedState else {
            throw AuthError.stateMismatch
        }
        guard let code = dict["code"], !code.isEmpty else {
            throw AuthError.missingCode
        }
        return code
    }

    private func exchangeCodeForToken(
        _ code: String,
        verifier: String
    ) async throws -> StoredToken {
        var request = URLRequest(url: URL(string: "https://lichess.org/api/token")!)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formURLEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "client_id": clientID,
        ]).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw AuthError.tokenExchangeFailed(
                httpStatus: status,
                body: String(data: data, encoding: .utf8)
            )
        }

        struct TokenResponse: Decodable {
            let token_type: String
            let access_token: String
            let expires_in: Int
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return StoredToken(
            accessToken: decoded.access_token,
            // Lichess' `/api/token` reply doesn't include the granted scope
            // string; we pass through what we requested. If the server-side
            // grants ever diverge, a 403 on the first protected endpoint
            // surfaces it.
            scope: scope,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    /// Builds an `application/x-www-form-urlencoded` body. We delegate to
    /// `URLComponents.percentEncodedQuery` to get the canonical encoding
    /// (`+` for space, percent-encoded reserveds), then pull the string
    /// without the leading `?`.
    private static func formURLEncoded(_ params: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }
}
