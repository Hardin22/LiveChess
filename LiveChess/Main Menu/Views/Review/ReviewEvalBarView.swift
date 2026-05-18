import SwiftUI

/// Floating vertical eval bar shown beside the immersive board during
/// review. Reads `ReviewSession.currentClassification` for the eval at
/// the current ply, converts to white-POV win-percentage via the same
/// tanh sigmoid the analyzer uses, then renders a Lichess-style split
/// bar — white fills from the bottom, black from the top, meeting at
/// the win-share line.
@MainActor
struct ReviewEvalBarView: View {

    @Bindable var session: ReviewSession

    private let barHeight: CGFloat = 320
    private let barWidth: CGFloat = 32

    var body: some View {
        VStack(spacing: 8) {
            scoreLabel
            bar
        }
        .padding(10)
        .background(.regularMaterial, in:
                        RoundedRectangle(cornerRadius: Chess.Radius.card,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Score label

    private var scoreLabel: some View {
        Text(scoreText)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(whiteShare >= 0.5 ? Chess.Palette.accent : .red)
            .frame(width: barWidth + 20)
    }

    /// "+1.20" / "-0.85" / "M3" / "−M5". Mate scores from `mateToCp`
    /// land at ±10000ish; everything else is cp/100 with sign.
    private var scoreText: String {
        let cp = whiteCp
        if cp >= 9000  { return "M\(10_000 - cp)" }
        if cp <= -9000 { return "-M\(10_000 + cp)" }
        return String(format: "%+.2f", Double(cp) / 100)
    }

    // MARK: - Bar

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Background = black side
                Rectangle()
                    .fill(Color(white: 0.10))
                // White side, height proportional to win share
                Rectangle()
                    .fill(Color(white: 0.95))
                    .frame(height: geo.size.height * CGFloat(whiteShare))
                    .animation(.spring(response: 0.5, dampingFraction: 0.85),
                               value: whiteShare)

                // Midline marker — helps eyeball whether we're above or
                // below 50/50.
                Rectangle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(width: barWidth, height: barHeight)
    }

    // MARK: - Eval math

    /// Centipawn score from white's point of view at the current ply.
    /// Analysis records hold the eval in mover POV, so we sign-flip
    /// when black moved.
    private var whiteCp: Int {
        guard let a = session.currentClassification else { return 0 }
        return (a.mover == .white) ? a.playedScoreCp : -a.playedScoreCp
    }

    /// `50 + 50·tanh(cp/400)` mapped to 0…1. Matches the chess.com /
    /// analyzer win-share formula — saturating sigmoid so a +5 doesn't
    /// look the same as a +20 (both heavily winning, but the bar pegs).
    private var whiteShare: Double {
        let pawns = Double(whiteCp) / 400.0
        let percent = 50.0 + 50.0 * tanh(pawns)
        return max(0.02, min(0.98, percent / 100.0))
    }
}
