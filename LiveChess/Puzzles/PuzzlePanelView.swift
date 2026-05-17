import SwiftUI

/// Companion floating panel for the immersive puzzle scene — shown
/// on the OPPOSITE side of the 3-D board from the action HUD, the
/// same way `MovesPanelView` does for live matches.
///
/// Surfaces:
///   * Theme chips (mate-in-2, fork, discovered-attack, …) so the
///     player knows what kind of tactic they're hunting for
///   * Moves played so far, numbered, with the most recent ply
///     highlighted — matches the chess.com / Lichess sidebar look
///   * "Your turn — find the best move for [color]" indicator that
///     reads as a clear call-to-action while the engine waits
///   * Hint button (asks `PuzzleSession.showHint()`, which sets a
///     flag the renderer can use to pulse the source square)
///   * View solution button — auto-plays the remaining moves with
///     a half-second beat between each so the player can SEE the
///     intended line, not just read it.
@MainActor
struct PuzzlePanelView: View {

    @Bindable var session: PuzzleSession

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            header
            Divider()
            yourTurnSection
            Divider()
            movesList
            Divider()
            actionsFooter
        }
        .padding(Chess.Space.m)
        .frame(width: 300, height: 480, alignment: .top)
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
                Text("Puzzle moves")
                    .font(.callout.weight(.semibold))
                if !session.puzzle.themes.isEmpty {
                    Text(session.puzzle.themes.prefix(3)
                            .map { $0.capitalized }
                            .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Your-turn callout

    @ViewBuilder
    private var yourTurnSection: some View {
        switch session.status {
        case .solving:
            HStack(spacing: Chess.Space.s) {
                Image(systemName: session.humanSide == .white
                      ? "crown.fill" : "crown")
                    .foregroundStyle(session.humanSide == .white
                                     ? .white : .black)
                    .font(.title2)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isHumanTurn
                         ? "Your turn"
                         : "Opponent thinking…")
                        .font(.callout.weight(.semibold))
                    Text(session.isHumanTurn
                         ? "Find the best move for \(session.humanSide == .white ? "white" : "black")."
                         : "Watch the reply, then it's you again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .solved:
            HStack(spacing: Chess.Space.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Chess.Palette.accent)
                    .font(.title3)
                Text("Solved — nice find!")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Chess.Palette.accent)
            }
        case .failed:
            HStack(spacing: Chess.Space.xs) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not the puzzle solution")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                    Text("Use the controls below to retry or reveal it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Move list

    private var movesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(movePairs, id: \.number) { pair in
                        HStack(spacing: 6) {
                            Text("\(pair.number).")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            moveCell(pair.white,
                                     isCurrent: pair.whiteIsCurrent)
                            moveCell(pair.black,
                                     isCurrent: pair.blackIsCurrent)
                            Spacer(minLength: 0)
                        }
                        .id(pair.number)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.match.moves.count) { _, _ in
                if let last = movePairs.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.number, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private struct MovePair {
        let number: Int
        let white: String?
        let black: String?
        let whiteIsCurrent: Bool
        let blackIsCurrent: Bool
    }

    private var movePairs: [MovePair] {
        let moves = session.match.moves
        let lastIdx = moves.count - 1
        var pairs: [MovePair] = []
        var i = 0
        while i < moves.count {
            pairs.append(MovePair(
                number: i / 2 + 1,
                white: moves[i].uci,
                black: i + 1 < moves.count ? moves[i + 1].uci : nil,
                whiteIsCurrent: i == lastIdx,
                blackIsCurrent: (i + 1) == lastIdx
            ))
            i += 2
        }
        return pairs
    }

    @ViewBuilder
    private func moveCell(_ uci: String?, isCurrent: Bool) -> some View {
        if let uci {
            Text(uci)
                .font(.callout.monospaced())
                .foregroundStyle(isCurrent ? .white : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isCurrent
                        ? AnyShapeStyle(Chess.Palette.info)
                        : AnyShapeStyle(.thinMaterial),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        } else {
            Color.clear.frame(width: 50, height: 1)
        }
    }

    // MARK: - Actions footer

    @ViewBuilder
    private var actionsFooter: some View {
        switch session.status {
        case .solving:
            HStack(spacing: Chess.Space.m) {
                Button {
                    session.showHint()
                } label: {
                    Label("Get a hint", systemImage: "lightbulb.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chess.Palette.info)
                .hoverEffect(.highlight)
                Spacer()
                Button {
                    Task { await session.revealSolution() }
                } label: {
                    Label("View solution", systemImage: "eye.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chess.Palette.info)
                .hoverEffect(.highlight)
            }
        case .failed:
            HStack(spacing: Chess.Space.m) {
                Button {
                    session.restart()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.accent)
                Spacer()
                Button {
                    Task { await session.revealSolution() }
                } label: {
                    Label("Solution", systemImage: "eye.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        case .solved:
            EmptyView()
        }
    }
}
