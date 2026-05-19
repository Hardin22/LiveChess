import SwiftUI

/// Live 2-D swatch of the board, mirroring whatever
/// `PieceCustomization.current` currently has set for the squares
/// + frame + tint. Updates in real time as the user changes any
/// board control on the customization sheet — same role
/// `PiecePreviewView` plays for pieces.
///
/// Renders as a 4×4 mini chess board nested inside a rounded frame:
///   * `lightSquareColor` / `darkSquareColor` fill the 16 cells
///   * `frameColor` paints the surrounding border + a thin inner
///     groove (mimics the real 3-D board's frame inset)
///   * Two sample pieces (one per side) sit on the board so the
///     player can see how their selected piece tint reads against
///     the chosen square palette
///
/// Pure SwiftUI — no RealityView, no heavy resources. Cheap enough
/// to re-render on every slider tick.
struct BoardPreviewView: View {
    let material: PieceMaterial

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let frameWidth = side * 0.08
            let innerSide = side - frameWidth * 2
            let cell = innerSide / 4

            ZStack {
                // FRAME — outer rounded rectangle painted with the
                // user's frame colour. The squares sit on top of it
                // so the visible border is the frame.
                RoundedRectangle(cornerRadius: side * 0.06,
                                 style: .continuous)
                    .fill(material.frameColor.swiftUI)
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.06,
                                         style: .continuous)
                            .strokeBorder(.white.opacity(0.18),
                                          lineWidth: 0.5)
                    )

                // INSET GROOVE — thin dark line between frame and
                // playable area, mirrors the real board's BoardGroove.
                RoundedRectangle(cornerRadius: side * 0.03,
                                 style: .continuous)
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.6)
                    .frame(width: innerSide + 2, height: innerSide + 2)

                // PLAYABLE 4×4 GRID — light/dark squares.
                VStack(spacing: 0) {
                    ForEach(0..<4) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<4) { col in
                                Rectangle()
                                    .fill(squareColor(row: row, col: col))
                                    .frame(width: cell, height: cell)
                                    .overlay(pieceGlyph(row: row, col: col,
                                                        cellSize: cell))
                            }
                        }
                    }
                }
                .frame(width: innerSide, height: innerSide)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.025,
                                            style: .continuous))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Square colouring

    private func squareColor(row: Int, col: Int) -> Color {
        let isLight = (row + col) % 2 == 0
        return isLight
            ? material.lightSquareColor.swiftUI
            : material.darkSquareColor.swiftUI
    }

    /// Two sample pieces — a white king on (3, 0) and a black king
    /// on (0, 3) — so the player sees how each side's tint sits on
    /// each square colour at the same time.
    @ViewBuilder
    private func pieceGlyph(row: Int, col: Int, cellSize: CGFloat) -> some View {
        if row == 3 && col == 0 {
            Text("\u{2654}")     // ♔ white king
                .font(.system(size: cellSize * 0.85))
                .foregroundStyle(material.whiteColor.swiftUI)
        } else if row == 0 && col == 3 {
            Text("\u{265A}")     // ♚ black king
                .font(.system(size: cellSize * 0.85))
                .foregroundStyle(material.blackColor.swiftUI)
        }
    }
}
