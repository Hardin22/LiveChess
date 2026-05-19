import SwiftUI

/// Renders a chess position from a FEN string as a compact 8×8 board,
/// used as the hero visual on puzzle browse cards. Shows the actual
/// position the user will solve instead of a generic puzzle-piece icon
/// — that's the distinctive visual cue for the new puzzles UI.
///
/// Cheap to render: 64 stacked rectangles + Unicode piece glyphs.
/// `size` is the OUTER side length in points; each square is `size/8`.
/// Pieces use Unicode chess symbols so we don't depend on any of the
/// app's 3D piece assets — the previews stay decoupled from the
/// renderer.
struct PuzzleMiniBoardView: View {

    let fen: String
    var size: CGFloat = 96
    /// Optional highlight: from–to squares of the puzzle's opponent
    /// set-up move ("lastMove" on the puzzle payload). When provided
    /// we tint those squares so the player can see where the action
    /// is even before tapping in.
    var lastMove: (from: (Int, Int), to: (Int, Int))? = nil

    var body: some View {
        let squareSize = size / 8
        let board = Self.parse(fen)

        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { col in
                        ZStack {
                            Rectangle()
                                .fill(Self.squareColor(row: row, col: col))
                            if isHighlighted(row: row, col: col) {
                                Rectangle()
                                    .fill(Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.55))
                            }
                            if let piece = board[row][col] {
                                Text(Self.glyph(for: piece))
                                    .font(.system(size: squareSize * 0.78))
                                    .foregroundStyle(piece.isUppercase
                                                     ? Color.white
                                                     : Color.black)
                                    .shadow(color: .black.opacity(0.35), radius: 0.4)
                            }
                        }
                        .frame(width: squareSize, height: squareSize)
                    }
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

    private func isHighlighted(row: Int, col: Int) -> Bool {
        guard let mv = lastMove else { return false }
        return (mv.from.0 == row && mv.from.1 == col) ||
               (mv.to.0   == row && mv.to.1   == col)
    }

    // MARK: - FEN parsing

    /// Returns an 8×8 grid of optional ASCII characters (KQRBNPkqrbnp).
    /// Row 0 is rank 8 (top), row 7 is rank 1, matching the visual.
    static func parse(_ fen: String) -> [[Character?]] {
        let empty: [[Character?]] = Array(
            repeating: Array(repeating: nil, count: 8),
            count: 8
        )
        let firstField = fen.split(separator: " ").first.map(String.init) ?? ""
        let ranks = firstField.split(separator: "/").map(String.init)
        guard ranks.count == 8 else { return empty }

        var result: [[Character?]] = empty
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

    /// Light/dark wood tones matching the in-app board (`Materials.swift`
    /// `lightSquare`/`darkSquare` colours, slightly muted for the
    /// preview so it reads as a thumbnail not the real game board).
    static func squareColor(row: Int, col: Int) -> Color {
        (row + col).isMultiple(of: 2)
            ? Color(red: 0.93, green: 0.86, blue: 0.71)   // light wood
            : Color(red: 0.55, green: 0.39, blue: 0.27)   // dark wood
    }

    /// Map FEN ASCII to a Unicode chess piece glyph. Returns a space
    /// for unrecognised input so the layout doesn't tear.
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
