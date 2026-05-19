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
                    .overlay(frameMaterialEffect)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.06,
                                                style: .continuous))
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
                                squareCell(row: row, col: col, cellSize: cell)
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
        .id(previewIdentity)
    }

    // MARK: - Square colouring

    private func squareColor(row: Int, col: Int) -> Color {
        let isLight = (row + col) % 2 == 0
        return isLight
            ? material.lightSquareColor.swiftUI
            : material.darkSquareColor.swiftUI
    }

    private var previewIdentity: String {
        [
            material.squareMaterial.rawValue,
            material.frameMaterial.rawValue,
            colorIdentity(material.lightSquareColor),
            colorIdentity(material.darkSquareColor),
            colorIdentity(material.frameColor),
            material.lightSquareWood.rawValue,
            material.darkSquareWood.rawValue,
            material.frameWood.rawValue
        ].joined(separator: "-")
    }

    private func colorIdentity(_ color: PieceColor) -> String {
        "\(color.red)-\(color.green)-\(color.blue)"
    }

    private func squareCell(row: Int, col: Int, cellSize: CGFloat) -> some View {
        let isLight = (row + col) % 2 == 0
        return ZStack {
            Rectangle()
                .fill(squareColor(row: row, col: col))
            boardMaterialEffect(
                material.squareMaterial,
                isLight: isLight,
                wood: isLight ? material.lightSquareWood : material.darkSquareWood
            )
            pieceGlyph(row: row, col: col, cellSize: cellSize)
        }
        .frame(width: cellSize, height: cellSize)
        .clipped()
    }

    @ViewBuilder
    private var frameMaterialEffect: some View {
        boardMaterialEffect(material.frameMaterial, isLight: false, wood: material.frameWood)
    }

    @ViewBuilder
    private func boardMaterialEffect(
        _ boardMaterial: BoardMaterial,
        isLight: Bool,
        wood: WoodType
    ) -> some View {
        switch boardMaterial {
        case .matte:
            Rectangle()
                .fill(.black.opacity(isLight ? 0.025 : 0.05))
        case .polished:
            ZStack {
                LinearGradient(
                    colors: [.white.opacity(0.26), .clear, .black.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [.clear, .white.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .blendMode(.screen)
        case .wood:
            woodEffect(isLight: isLight, wood: wood)
        case .marble:
            marbleEffect(isLight: isLight)
        }
    }

    private func woodEffect(isLight: Bool, wood: WoodType) -> some View {
        ZStack {
            LinearGradient(
                colors: woodGradient(wood),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(.black.opacity(isLight ? 0.10 : 0.18))
                        .frame(width: proxy.size.width * 1.25, height: 1)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? 8 : -6))
                        .offset(
                            x: -proxy.size.width * 0.10,
                            y: proxy.size.height * CGFloat(index) / 6.0
                        )
                }
            }
        }
        .blendMode(.multiply)
    }

    private func marbleEffect(isLight: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: isLight
                    ? [.white.opacity(0.42), .gray.opacity(0.16), .white.opacity(0.22)]
                    : [.white.opacity(0.16), .black.opacity(0.12), .white.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(isLight ? 0.34 : 0.20))
                        .frame(width: proxy.size.width * 1.15, height: 1.2)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -24 : 18))
                        .offset(
                            x: -proxy.size.width * 0.08,
                            y: proxy.size.height * (CGFloat(index) + 0.8) / 4.5
                        )
                }
            }
        }
        .blendMode(.screen)
    }

    private func woodGradient(_ wood: WoodType) -> [Color] {
        switch wood {
        case .oak:
            return [
                Color(red: 0.82, green: 0.62, blue: 0.34).opacity(0.45),
                Color(red: 0.48, green: 0.31, blue: 0.14).opacity(0.32)
            ]
        case .walnut:
            return [
                Color(red: 0.42, green: 0.24, blue: 0.12).opacity(0.50),
                Color(red: 0.20, green: 0.11, blue: 0.06).opacity(0.42)
            ]
        case .rosewood:
            return [
                Color(red: 0.54, green: 0.20, blue: 0.12).opacity(0.48),
                Color(red: 0.25, green: 0.08, blue: 0.05).opacity(0.42)
            ]
        case .ebony:
            return [
                Color(red: 0.12, green: 0.10, blue: 0.08).opacity(0.52),
                Color.black.opacity(0.50)
            ]
        }
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
