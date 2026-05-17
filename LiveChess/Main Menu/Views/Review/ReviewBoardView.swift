import SwiftUI

/// Inline 2-D chessboard view used by the Game Review detail screen.
///
/// Renders any `Position` as an 8×8 grid with unicode glyphs for the
/// pieces, plus an optional arrow overlay for "this is what was played"
/// (orange) and "this is what the engine wanted" (accent green). Used
/// instead of an embedded RealityView because:
///
///   * The review screen is a 2-D Vision Pro window, not an
///     immersive space — there's no AR/MR context to anchor to.
///   * Scrubbing through 80 plies of a game means rebuilding the
///     scene 80 times; the 2-D grid is essentially free.
///   * The 3-D immersive board already handles the actual play
///     experience; the review window is its companion analysis tool.
struct ReviewBoardView: View {

    let position: Position
    /// Move the player actually played from this position (orange).
    let playedMove: Move?
    /// Move the engine preferred (accent green). Hidden when it
    /// matches `playedMove`.
    let bestMove: Move?
    /// `true` to flip the board so Black sits at the bottom.
    let flipped: Bool

    init(
        position: Position,
        playedMove: Move? = nil,
        bestMove: Move? = nil,
        flipped: Bool = false
    ) {
        self.position = position
        self.playedMove = playedMove
        self.bestMove = bestMove
        self.flipped = flipped
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let squareSize = side / 8
            ZStack {
                board(squareSize: squareSize)
                arrowLayer(squareSize: squareSize)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func board(squareSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(displayRanks, id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(displayFiles, id: \.self) { file in
                        squareCell(file: file, rank: rank, size: squareSize)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func squareCell(file: Int, rank: Int, size: CGFloat) -> some View {
        let isLight = (file + rank) % 2 == 1
        let square = Square(file: file, rank: rank)!
        let piece = position[square]
        let highlight = highlightFor(square)

        ZStack {
            Rectangle()
                .fill(isLight
                      ? Color(red: 0.93, green: 0.93, blue: 0.84)
                      : Chess.Palette.accent.opacity(0.78))
            if let highlight {
                Rectangle().fill(highlight.opacity(0.45))
            }
            if let piece {
                Text(String(piece.unicodeGlyph))
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(.black)
                    .shadow(color: .white.opacity(0.25),
                            radius: 0.5, x: 0, y: 0.3)
            }
            // File / rank labels on the edges, like Lichess.
            labelOverlay(file: file, rank: rank, size: size, isLight: isLight)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func labelOverlay(file: Int, rank: Int, size: CGFloat, isLight: Bool) -> some View {
        let labelColor: Color = isLight
            ? Chess.Palette.accent.opacity(0.85)
            : Color(red: 0.93, green: 0.93, blue: 0.84).opacity(0.85)
        let showFile = (flipped ? rank == 7 : rank == 0)
        let showRank = (flipped ? file == 7 : file == 0)
        ZStack {
            if showRank {
                Text("\(rank + 1)")
                    .font(.system(size: size * 0.18, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .padding(2)
            }
            if showFile {
                Text(String(Character(UnicodeScalar(97 + file)!)))
                    .font(.system(size: size * 0.18, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(2)
            }
        }
    }

    private func highlightFor(_ square: Square) -> Color? {
        if let p = playedMove, p.from == square || p.to == square {
            return .yellow
        }
        return nil
    }

    @ViewBuilder
    private func arrowLayer(squareSize: CGFloat) -> some View {
        ZStack {
            if let played = playedMove {
                MoveArrow(from: played.from, to: played.to,
                          squareSize: squareSize, flipped: flipped,
                          color: .yellow.opacity(0.85))
            }
            if let best = bestMove, best != playedMove {
                MoveArrow(from: best.from, to: best.to,
                          squareSize: squareSize, flipped: flipped,
                          color: Chess.Palette.accent.opacity(0.95))
            }
        }
        .allowsHitTesting(false)
    }

    private var displayRanks: [Int] {
        flipped ? Array(0...7) : Array(0...7).reversed()
    }

    private var displayFiles: [Int] {
        flipped ? Array(0...7).reversed() : Array(0...7)
    }
}

// MARK: - Move arrow overlay

private struct MoveArrow: View {
    let from: Square
    let to: Square
    let squareSize: CGFloat
    let flipped: Bool
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let p1 = centre(for: from, in: size)
            let p2 = centre(for: to, in: size)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            ctx.stroke(path, with: .color(color),
                       style: .init(lineWidth: squareSize * 0.18,
                                    lineCap: .round))
            // Arrowhead
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let len = max(0.0001, sqrt(dx*dx + dy*dy))
            let ux = dx / len, uy = dy / len
            let head = squareSize * 0.35
            let left = CGPoint(
                x: p2.x - ux * head - uy * head * 0.5,
                y: p2.y - uy * head + ux * head * 0.5
            )
            let right = CGPoint(
                x: p2.x - ux * head + uy * head * 0.5,
                y: p2.y - uy * head - ux * head * 0.5
            )
            var headPath = Path()
            headPath.move(to: p2)
            headPath.addLine(to: left)
            headPath.addLine(to: right)
            headPath.closeSubpath()
            ctx.fill(headPath, with: .color(color))
        }
    }

    /// Centre-of-square in canvas coordinates, honouring board flip.
    private func centre(for square: Square, in size: CGSize) -> CGPoint {
        let s = min(size.width, size.height) / 8
        let file = flipped ? (7 - square.file) : square.file
        let rank = flipped ? square.rank : (7 - square.rank)
        return CGPoint(
            x: CGFloat(file) * s + s / 2,
            y: CGFloat(rank) * s + s / 2
        )
    }
}

// MARK: - Piece unicode glyphs

private extension Piece {
    /// Standard Unicode chess glyphs (U+2654…U+265F).
    var unicodeGlyph: Character {
        switch (color, kind) {
        case (.white, .king):   return "\u{2654}"
        case (.white, .queen):  return "\u{2655}"
        case (.white, .rook):   return "\u{2656}"
        case (.white, .bishop): return "\u{2657}"
        case (.white, .knight): return "\u{2658}"
        case (.white, .pawn):   return "\u{2659}"
        case (.black, .king):   return "\u{265A}"
        case (.black, .queen):  return "\u{265B}"
        case (.black, .rook):   return "\u{265C}"
        case (.black, .bishop): return "\u{265D}"
        case (.black, .knight): return "\u{265E}"
        case (.black, .pawn):   return "\u{265F}"
        }
    }
}
