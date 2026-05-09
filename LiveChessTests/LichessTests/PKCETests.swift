import Testing
import Foundation
import CryptoKit
@testable import LiveChess

/// Verifies the PKCE helpers produce values that conform to RFC 7636 and
/// that the verifier ↔ challenge relationship Lichess will check on the
/// server is mathematically correct.
@Suite("PKCE")
struct PKCETests {

    @Test
    func verifierUsesBase64URLAlphabetAndExpectedLength() {
        let verifier = PKCE.generateCodeVerifier()

        // 32 bytes → 43 chars after base64url-no-pad encoding (ceil(32 * 4 / 3) = 43).
        // RFC 7636 §4.1 mandates 43 ≤ length ≤ 128.
        #expect(verifier.count == 43)

        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let used = CharacterSet(charactersIn: verifier)
        #expect(used.isSubset(of: allowed),
                "verifier contains chars outside the base64url alphabet: \(verifier)")
        #expect(!verifier.contains("="), "verifier must not be padded")
    }

    @Test
    func verifierIsHighEntropy() {
        // Heuristic: if the generator is broken (e.g. always returns the same
        // value, or has very low entropy), 1000 samples will collide. Real
        // CSPRNG output has effectively zero collision probability at this
        // sample size for a 256-bit space.
        let samples = (0..<1000).map { _ in PKCE.generateCodeVerifier() }
        #expect(Set(samples).count == samples.count)
    }

    @Test
    func challengeMatchesS256OfVerifier() {
        // Re-implement the spec equation here so the test is independent
        // of the production helper, then cross-check.
        let verifier = PKCE.generateCodeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)

        let expected = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(challenge == expected)
    }

    @Test
    func challengeIsBase64URLNoPaddingFixedLength() {
        let challenge = PKCE.codeChallenge(for: PKCE.generateCodeVerifier())
        // SHA-256 → 32 bytes → 43 chars after base64url-no-pad.
        #expect(challenge.count == 43)
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test
    func challengeIsDeterministicForGivenVerifier() {
        // Lichess will recompute SHA256(verifier) server-side and compare
        // against the challenge we sent on the authorize call. The function
        // must therefore be a pure deterministic transform.
        let verifier = "fixed-test-verifier-for-determinism-check-12345"
        let a = PKCE.codeChallenge(for: verifier)
        let b = PKCE.codeChallenge(for: verifier)
        #expect(a == b)
    }

    @Test
    func challengeMatchesRFC7636AppendixBVector() {
        // RFC 7636 Appendix B fixed test vector. If we ever break this we've
        // broken interop with literally every PKCE-compliant server.
        let verifier =
            "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.codeChallenge(for: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func stateIsRandomAndBase64URL() {
        let a = PKCE.generateState()
        let b = PKCE.generateState()
        #expect(a != b)
        #expect(!a.contains("="))
        #expect(!a.contains("+"))
        #expect(!a.contains("/"))
        #expect(a.count >= 16)
    }
}
