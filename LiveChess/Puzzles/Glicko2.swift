import Foundation

/// Glicko-2 rating system — the algorithm Lichess uses for both
/// puzzle ratings and all timed/correspondence chess ratings.
/// Reference paper: http://www.glicko.net/glicko/glicko2.pdf
///
/// We apply it as a single-game period each time the user solves
/// or fails a puzzle. Score is `1.0` for a solve (= win), `0.0`
/// for a fail (= loss). The puzzle's rating is the "opponent" in
/// the mini-match; its rating deviation is taken to be small
/// (default 60) because Lichess's published puzzle ratings are
/// based on thousands of solver attempts and are well-stabilised.
///
/// Constants match Lichess:
///   • Tau (system volatility constraint) = 0.5
///   • Conversion factor 173.7178 (Glicko-1 → Glicko-2 scale)
///   • Default new-player rating / RD / volatility = 1500 / 350 / 0.06
enum Glicko2 {

    /// One player's rating state in Glicko-2.
    struct Rating: Codable, Equatable, Sendable {
        var rating: Double          // Glicko-1 scale (≈1500 for new)
        var rd: Double              // rating deviation
        var volatility: Double      // σ (sigma)

        static let initial = Rating(rating: 1500, rd: 350, volatility: 0.06)
    }

    static let tau: Double = 0.5
    static let scale: Double = 173.7178

    /// Apply one match result to `player`. `opponentRating` and
    /// `opponentRD` describe the puzzle. `score` is 1 (solve) or 0
    /// (fail); a draw would be 0.5 but puzzles don't draw.
    static func update(player: Rating,
                       opponentRating: Double,
                       opponentRD: Double = 60,
                       score: Double) -> Rating {
        // Step 1 — convert to Glicko-2 scale.
        let mu = (player.rating - 1500) / scale
        let phi = player.rd / scale
        let muJ = (opponentRating - 1500) / scale
        let phiJ = opponentRD / scale
        let sigma = player.volatility

        // Step 2 — g(φⱼ) and expected score E.
        let gJ = 1 / sqrt(1 + 3 * phiJ * phiJ / (.pi * .pi))
        let E  = 1 / (1 + exp(-gJ * (mu - muJ)))

        // Step 3 — variance v from the game.
        let v = 1 / (gJ * gJ * E * (1 - E))

        // Step 4 — estimated improvement Δ.
        let delta = v * gJ * (score - E)

        // Step 5 — new volatility (iterative Illinois root-finder).
        let newSigma = updatedVolatility(sigma: sigma,
                                         phi: phi,
                                         v: v,
                                         delta: delta)

        // Step 6 — new rating deviation.
        let phiStar = sqrt(phi * phi + newSigma * newSigma)
        let newPhi = 1 / sqrt(1 / (phiStar * phiStar) + 1 / v)

        // Step 7 — new rating.
        let newMu = mu + newPhi * newPhi * gJ * (score - E)

        // Step 8 — back to Glicko-1 scale.
        return Rating(
            rating: scale * newMu + 1500,
            rd:     scale * newPhi,
            volatility: newSigma
        )
    }

    // MARK: - Volatility update (the gnarly part)

    private static func updatedVolatility(sigma: Double,
                                          phi: Double,
                                          v: Double,
                                          delta: Double) -> Double {
        let a = log(sigma * sigma)
        let phiSq = phi * phi
        let deltaSq = delta * delta

        func f(_ x: Double) -> Double {
            let ex = exp(x)
            let num = ex * (deltaSq - phiSq - v - ex)
            let den = 2 * pow(phiSq + v + ex, 2)
            return num / den - (x - a) / (tau * tau)
        }

        var A = a
        var B: Double
        if deltaSq > phiSq + v {
            B = log(deltaSq - phiSq - v)
        } else {
            var k: Double = 1
            while f(a - k * tau) < 0 {
                k += 1
            }
            B = a - k * tau
        }

        var fA = f(A)
        var fB = f(B)
        let epsilon = 1e-6
        var iterations = 0
        while abs(B - A) > epsilon, iterations < 100 {
            iterations += 1
            let C = A + (A - B) * fA / (fB - fA)
            let fC = f(C)
            if fC * fB <= 0 {
                A = B
                fA = fB
            } else {
                fA /= 2
            }
            B = C
            fB = fC
        }

        return exp(A / 2)
    }
}
