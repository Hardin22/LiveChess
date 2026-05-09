import Foundation
import CryptoKit

/// Pure-Swift helpers for the OAuth 2.0 **PKCE** (Proof Key for Code Exchange,
/// RFC 7636) flow used to authenticate against Lichess from the visionOS app.
///
/// Lichess only accepts the `S256` code-challenge method
/// (`https://lichess.org/api#section/Authentication`), so all we need is:
///
///   * a high-entropy `code_verifier` (random URL-safe string, 43–128 chars),
///   * its `code_challenge`, computed as `BASE64URL(SHA256(verifier))`,
///   * an opaque `state` value to bind the authorize / redirect round-trip
///     against CSRF.
///
/// All output strings are base64url-encoded with the trailing `=` padding
/// stripped, exactly as RFC 7636 §4.2 requires.
enum PKCE {

    /// Length-in-bytes of the entropy seed used for both the verifier and the
    /// state parameter. 32 bytes → 256 bits of entropy → 43 base64url chars
    /// after no-pad encoding, which is the minimum length the spec allows.
    static let entropyByteCount = 32

    /// Generates a fresh `code_verifier`. Each authorize request must use a
    /// new verifier; never reuse one across attempts.
    static func generateCodeVerifier() -> String {
        base64URLEncoded(randomBytes(entropyByteCount))
    }

    /// Computes the `code_challenge` for the given verifier using `S256`.
    /// The result is what gets sent on the authorize URL; the verifier
    /// itself stays inside the app until the token-exchange POST.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    /// Generates an opaque `state` value to attach to the authorize request.
    /// Lichess echoes it back on the redirect; the app must verify it
    /// matches before trading the code for a token (CSRF protection per
    /// RFC 6749 §10.12).
    static func generateState() -> String {
        base64URLEncoded(randomBytes(16))
    }

    // MARK: - Private

    /// `SecRandomCopyBytes` is the CSPRNG Apple recommends for crypto
    /// material on Darwin; it cannot fail in practice (returns errSecSuccess)
    /// but we still trap a non-success to fail loudly rather than ship a
    /// predictable verifier.
    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    /// Base64URL-encodes `data` with **no padding**, per RFC 7636 §4.2 and
    /// RFC 4648 §5. The standard library only ships base64-with-padding, so
    /// we hand-translate the three character substitutions.
    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
