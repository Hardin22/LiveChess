import SwiftUI

/// Compact 8×8 chessboard preview, rendered as a single SwiftUI
/// `Canvas` draw call so the puzzle browser stays smooth even with
/// dozens of cards on screen at once. (The earlier stacked-rectangles
/// implementation created ~128 SwiftUI nodes per board × ~88 cards
/// per first-paint = >11k views, which was the source of the lag.)
///
/// `size` is the OUTER side length in points. Pass an optional
/// `lastMove` (the puzzle's set-up move, parsed by `PuzzleDeckCard`)
/// to gold-tint the source and destination squares.
struct PuzzleMiniBoardView: View {

    let fen: String
    var size: CGFloat = 96
    var lastMove: (from: (row: Int, col: Int), to: (row: Int, col: Int))? = nil

    var body: some View {
        let board = Self.parse(fen)
        let highlight = lastMove

        Canvas { context, canvasSize in
            let cell = canvasSize.width / 8

            // 1) Squares + optional from→to highlight.
            for row in 0..<8 {
                for col in 0..<8 {
                    let rect = CGRect(
                        x: CGFloat(col) * cell,
                        y: CGFloat(row) * cell,
                        width: cell, height: cell
                    )
                    var fill = Self.squareColor(row: row, col: col)
                    if let h = highlight,
                       (h.from.row == row && h.from.col == col) ||
                       (h.to.row   == row && h.to.col   == col) {
                        // Warm gold wash over the original square so the
                        // highlight reads on both light and dark squares.
                        context.fill(Path(rect), with: .color(fill))
                        fill = Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.55)
                    }
                    context.fill(Path(rect), with: .color(fill))
                }
            }

            // 2) Pieces — drawn as Unicode glyphs centred on each
            //    occupied square. Canvas `draw(Text, at:)` resolves
            //    once per glyph and is much cheaper than mounting
            //    a SwiftUI Text per square.
            let pieceFont = Font.system(size: cell * 0.82,
                                        weight: .regular,
                                        design: .default)
            for row in 0..<8 {
                for col in 0..<8 {
                    guard let piece = board[row][col] else { continue }
                    let glyph = Self.glyph(for: piece)
                    let textColor: Color = piece.isUppercase ? .white : .black
                    let resolved = context.resolve(
                        Text(glyph)
                            .font(pieceFont)
                            .foregroundStyle(textColor)
                    )
                    let centre = CGPoint(
                        x: (CGFloat(col) + 0.5) * cell,
                        y: (CGFloat(row) + 0.5) * cell
                    )
                    context.draw(resolved, at: centre, anchor: .center)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.06))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.06)
                .strokeBorder(.black.opacity(0.18), lineWidth: 0.6)
        )
    }

    // MARK: - FEN parsing

    /// 8×8 grid (row 0 = rank 8) of optional ASCII piece chars.
    static func parse(_ fen: String) -> [[Character?]] {
        let empty: [[Character?]] = Array(
            repeating: Array(repeating: nil, count: 8),
            count: 8
        )
        let firstField = fen.split(separator: " ").first.map(String.init) ?? ""
        let ranks = firstField.split(separator: "/").map(String.init)
        guard ranks.count == 8 else { return empty }

        var result = empty
        for (r, rank) in ranks.enumerated() {
            var col = 0
            for ch in rank {
                if let n = ch.wholeNumberValue, (1...8).contains(n) {
                    col += n
                } else if col < 8 {
                    result[r][col] = ch
                    col += 1
                }
            }
        }
        return result
    }

    /// Wood tones that match the in-app board roughly (Materials.swift
    /// light/dark square colours, muted a touch so the preview reads
    /// as a thumbnail rather than the real game surface).
    static func squareColor(row: Int, col: Int) -> Color {
        (row + col).isMultiple(of: 2)
            ? Color(red: 0.93, green: 0.86, blue: 0.71)
            : Color(red: 0.55, green: 0.39, blue: 0.27)
    }

    static func glyph(for c: Character) -> String {
        switch c {
        case "K": return "♔"
        case "Q": return "♕"
        case "R": return "♖"
        case "B": return "♗"
        case "N": return "♘"
        case "P": return "♙"
        case "k": return "♚"
        case "q": return "♛"
        case "r": return "♜"
        case "b": return "♝"
        case "n": return "♞"
        case "p": return "♟"
        default:  return " "
        }
    }
}
