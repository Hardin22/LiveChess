import Foundation
import Observation

/// Top-level signed-in/out state for the Lichess integration.
///
/// `LichessSession` owns the singletons the rest of the app reaches for —
/// the keychain-backed token store, the OAuth service, and the REST API
/// client whose token mirror it keeps in sync. Higher layers
/// (`LichessLobbyController`, `LichessMatchSession`) are constructed
/// against this session and read the bearer token through it.
///
/// `bootstrap()` is the cold-start entry point: load the persisted token,
/// hit `/api/account` to confirm it's still valid, and either materialise
/// the signed-in account or wipe and show the sign-in CTA.
///
/// `signIn()` drives the full PKCE flow + token persist + account fetch.
/// `signOut()` revokes server-side, wipes the keychain, drops the cached
/// token. Both are idempotent w.r.t. UI state (calling them while in the
/// wrong status is a no-op).
@MainActor
@Observable
final class LichessSession {

    enum Status: Equatable, Sendable {
        /// `bootstrap()` hasn't run yet — UI shows a loading indicator.
        case unknown
        /// No token in keychain (or token was wiped) — UI shows sign-in CTA.
        case signedOut
        /// PKCE flow is in flight — UI shows progress.
        case signingIn
        /// Bearer token is valid; the snapshot is the account profile.
        case signedIn(LichessAccount)
        /// Token revoke + keychain wipe in flight — UI shows progress.
        case signingOut
        /// Last operation failed loudly enough to surface; carries a
        /// human-readable message. UI shows it then falls back to
        /// `signedOut`.
        case error(String)
    }

    private(set) var status: Status = .unknown

    /// Mirror of the bearer token currently held by `api`. Exposed so
    /// stream actors (which need the token at construction) and the
    /// lobby/match observers can wire themselves up without an actor hop.
    /// `nil` whenever `status != .signedIn(_)`.
    private(set) var token: String?

    let tokenStore: LichessTokenStore
    let authService: LichessAuthService
    let api: LichessAPIClient

    init(
        tokenStore: LichessTokenStore = LichessTokenStore(),
        authService: LichessAuthService = LichessAuthService(),
        api: LichessAPIClient = LichessAPIClient()
    ) {
        self.tokenStore = tokenStore
        self.authService = authService
        self.api = api
    }

    /// Convenience getter — `nil` unless we're actively signed in.
    var account: LichessAccount? {
        if case let .signedIn(a) = status { return a }
        return nil
    }

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    /// Cold-start initialisation. Should be called exactly once from the
    /// app's entry view (`.task { await session.bootstrap() }`). Reentrant
    /// calls short-circuit if we already have a definitive status.
    func bootstrap() async {
        if case .signedIn = status { return }   // already good
        if case .signingIn = status { return }  // user is mid-flow

        do {
            guard let stored = try await tokenStore.load() else {
                status = .signedOut
                return
            }
            await api.updateToken(stored.accessToken)
            token = stored.accessToken
            await fetchAccountAndApply()
        } catch {
            // Keychain read failure shouldn't block the app — just fall
            // back to signed-out so the user can re-auth.
            status = .signedOut
        }
    }

    /// Drives the OAuth PKCE flow end-to-end, persists the token, and
    /// fetches the account so the lobby card has everything it needs.
    func signIn() async {
        guard case .signedOut = status
              .normalizedForSignIn else { return }
        status = .signingIn
        do {
            let stored = try await authService.signIn()
            try await tokenStore.save(stored)
            await api.updateToken(stored.accessToken)
            token = stored.accessToken
            await fetchAccountAndApply()
        } catch LichessAuthService.AuthError.userCancelled {
            // Quietly return to signed-out — no error toast for user
            // intent. The CTA stays visible so they can retry.
            status = .signedOut
        } catch {
            status = .error(humanReadable(error))
            // Fall back to signed-out so the CTA reappears after the
            // banner is dismissed by the next bootstrap / refresh.
            try? await tokenStore.delete()
            await api.updateToken(nil)
            token = nil
        }
    }

    /// Logs out: revoke server-side, wipe keychain, drop cached token.
    /// Best-effort — even if the revoke fails (token already invalid),
    /// the local wipe happens.
    func signOut() async {
        guard case .signedIn = status else { return }
        status = .signingOut
        if let token {
            try? await authService.signOut(token: token)
        }
        try? await tokenStore.delete()
        await api.updateToken(nil)
        token = nil
        status = .signedOut
    }

    // MARK: - Private

    /// Fetches `/api/account` against the *current* token and updates
    /// status. On 401 we wipe; on other errors we surface.
    private func fetchAccountAndApply() async {
        do {
            let account = try await api.account()
            status = .signedIn(account)
        } catch LichessError.tokenExpired {
            try? await tokenStore.delete()
            await api.updateToken(nil)
            token = nil
            status = .signedOut
        } catch {
            // Keep the token — the issue may be transient (network blip,
            // 5xx). Surface so the lobby can show a "Riprova" affordance.
            status = .error(humanReadable(error))
        }
    }

    private func humanReadable(_ error: any Error) -> String {
        if let lichess = error as? LichessError {
            switch lichess {
            case .notAuthenticated:  return "Not signed in."
            case .tokenExpired:      return "Lichess session expired."
            case .scopeInsufficient: return "Insufficient Lichess permissions."
            case .rateLimited:       return "Lichess is rate-limiting — try again in a minute."
            case .clientError(let s, _): return "Lichess error (\(s))."
            case .serverError:       return "Lichess is not responding right now."
            case .decoding:          return "Unrecognized Lichess response."
            case .network:           return "No connection to Lichess."
            case .invalidResponse:   return "Invalid Lichess response."
            }
        }
        return "Error: \(error.localizedDescription)"
    }
}

private extension LichessSession.Status {
    /// `signIn()` is allowed from `.signedOut` and `.error(_)`. This
    /// helper collapses both into `.signedOut` for the guard.
    var normalizedForSignIn: LichessSession.Status {
        switch self {
        case .signedOut, .error:
            return .signedOut
        case .unknown, .signingIn, .signingOut, .signedIn:
            return self
        }
    }
}
