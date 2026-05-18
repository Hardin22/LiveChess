import SwiftUI

/// Companion panel surfaced opposite the review HUD on the immersive
/// board. Renders the full main-line move list with each ply's quality
/// glyph + colour inline, highlights the current ply, and lets the
/// user tap any move to jump directly to that position. Pairs with
/// `ReviewSession` for both navigation and live classification updates.
@MainActor
struct ReviewMovesPanelView: View {

    @Bindable var session: ReviewSession

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            header
            Divider()
            movesList
        }
        .padding(Chess.Space.m)
        .frame(width: 320, height: 460, alignment: .top)
        .background(.regularMaterial, in:
                        RoundedRectangle(cornerRadius: Chess.Radius.card,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Chess.Space.xs) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(Chess.Palette.info)
            VStack(alignment: .leading, spacing: 1) {
                Text("Moves")
                    .font(.callout.weight(.semibold))
                Text("\(session.plyMoves.count) plies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.isAnalyzing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Chess.Palette.accent)
            }
        }
    }

    // MARK: - Moves list

    private var movesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(pairs, id: \.number) { pair in
                        HStack(spacing: 6) {
                            Text("\(pair.number).")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            moveCell(pair.white)
                            moveCell(pair.black)
                            Spacer(minLength: 0)
                        }
                        .id(pair.number)
                    }
                    if session.isInVariation {
                        variationThread
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.currentPly) { _, ply in
                let pairNumber = max(1, ply / 2 + 1)
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(pairNumber, anchor: .center)
                }
            }
            .onChange(of: session.variation.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("variation-tip", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Indented "side line" thread shown when the user has dragged
    /// pieces to branch off the main game line. Each variation move
    /// renders with its classification glyph in the same style as
    /// main-line cells; quality slots are placeholder `good` until
    /// local Stockfish lands the eval, then they upgrade in place.
    private var variationThread: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(Chess.Palette.info)
                Text("Side line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Chess.Palette.info)
                Spacer(minLength: 0)
                Button("Reset") { session.clearVariation() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            .padding(.top, 6)
            .padding(.leading, 34)

            ForEach(Array(session.variation.enumerated()), id: \.offset) { idx, step in
                let analysis = idx < session.variationAnalysis.count
                    ? session.variationAnalysis[idx] : nil
                HStack(spacing: 6) {
                    Text("\(idx + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Chess.Palette.info.opacity(0.7))
                        .frame(width: 28, alignment: .trailing)
                    HStack(spacing: 4) {
                        Text(step.move.uci)
                            .font(.callout.monospaced())
                        if let q = analysis?.quality {
                            Text(q.glyph)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(qualityColor(q))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Chess.Palette.info.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
            }
            Color.clear.frame(height: 1).id("variation-tip")
        }
    }

    private struct Cell {
        let ply: Int
        let label: String
        let analysis: MoveAnalysis?
    }
    private struct Pair { let number: Int; let white: Cell?; let black: Cell? }

    private var pairs: [Pair] {
        var out: [Pair] = []
        let moves = session.plyMoves
        var i = 0
        while i < moves.count {
            let whitePly = i
            let blackPly = i + 1
            out.append(Pair(
                number: i / 2 + 1,
                white: Cell(
                    ply: whitePly,
                    label: moves[whitePly].uci,
                    analysis: session.analysisResults.indices.contains(whitePly)
                        ? session.analysisResults[whitePly] : nil
                ),
                black: blackPly < moves.count ? Cell(
                    ply: blackPly,
                    label: moves[blackPly].uci,
                    analysis: session.analysisResults.indices.contains(blackPly)
                        ? session.analysisResults[blackPly] : nil
                ) : nil
            ))
            i += 2
        }
        return out
    }

    @ViewBuilder
    private func moveCell(_ cell: Cell?) -> some View {
        if let cell {
            Button {
                session.jumpTo(ply: cell.ply)
            } label: {
                HStack(spacing: 4) {
                    Text(cell.label)
                        .font(.callout.monospaced())
                    if let q = cell.analysis?.quality {
                        Text(q.glyph)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(qualityColor(q))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(minWidth: 72, alignment: .leading)
                .background(
                    cell.ply == session.currentPly
                        ? AnyShapeStyle(Chess.Palette.accent.opacity(0.30))
                        : AnyShapeStyle(.thinMaterial),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        } else {
            Color.clear.frame(width: 72, height: 1)
        }
    }

    private func qualityColor(_ q: MoveQuality) -> Color {
        switch q {
        case .brilliant:        return .cyan
        case .best, .great:     return Chess.Palette.accent
        case .book:             return Chess.Palette.info
        case .excellent, .good: return .mint
        case .inaccuracy:       return Chess.Palette.highlight
        case .missedWin:        return .purple
        case .mistake:          return .orange
        case .blunder:          return .red
        }
    }
}
