import SwiftUI

/// Companion floating panel for the immersive chess scene — shown on
/// the opposite side of the board from the action HUD. Surfaces the
/// running move list (with opening name when known), scrub-style
/// navigation arrows, and a quick-action footer with Draw + Resign.
///
/// Renders for local matches only; the online Lichess HUD already
/// has its own draw / resign / takeback flow with the proper offer
/// dance. Puzzle and review sessions use their own dedicated panels
/// instead.
@MainActor
struct MovesPanelView: View {

    @Bindable var coordinator: MatchCoordinator
    @Environment(AppModel.self) private var appModel
    // Single pending confirmation, rendered inline below the footer.
    // `.confirmationDialog` can't present from an immersive-space
    // attachment, so we swap in an in-place row instead.
    private enum PendingConfirm: Equatable { case draw, resign }
    @State private var pendingConfirm: PendingConfirm?

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            header
            Divider()
            movesList
            Divider()
            actionsFooter
        }
        .padding(Chess.Space.m)
        .frame(width: 280, height: 460, alignment: .top)
        .background(.regularMaterial, in:
                        RoundedRectangle(cornerRadius: Chess.Radius.card,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Header (opening name)

    private var header: some View {
        HStack(spacing: Chess.Space.xs) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(Chess.Palette.info)
            VStack(alignment: .leading, spacing: 1) {
                Text("Moves")
                    .font(.callout.weight(.semibold))
                if let opening = currentOpeningName {
                    Text(opening)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Look up the opening for the current position via the bundled
    /// `OpeningBook` (lichess-org/chess-openings, ~3 700 named
    /// positions, EPD-keyed). Falls back to nil when the line drifts
    /// out of book — same heuristic the analyzer uses.
    private var currentOpeningName: String? {
        OpeningBook.shared
            .lookup(coordinator.match.currentPosition)
            .map { "\($0.eco) · \($0.name)" }
    }

    // MARK: - Moves list

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
                            moveCell(pair.white)
                            moveCell(pair.black)
                            Spacer(minLength: 0)
                        }
                        .id(pair.number)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: coordinator.match.moves.count) { _, _ in
                if let last = movePairs.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.number, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private struct MovePair { let number: Int; let white: String?; let black: String? }

    private var movePairs: [MovePair] {
        let moves = coordinator.match.moves
        var pairs: [MovePair] = []
        var i = 0
        while i < moves.count {
            pairs.append(MovePair(
                number: i / 2 + 1,
                white: moves[i].uci,
                black: i + 1 < moves.count ? moves[i + 1].uci : nil
            ))
            i += 2
        }
        return pairs
    }

    @ViewBuilder
    private func moveCell(_ uci: String?) -> some View {
        if let uci {
            Text(uci)
                .font(.callout.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial,
                            in: RoundedRectangle(cornerRadius: 6))
        } else {
            Color.clear.frame(width: 50, height: 1)
        }
    }

    // MARK: - Quick actions footer (½ Draw · ⚑ Resign)

    @ViewBuilder
    private var actionsFooter: some View {
        let humanSide: Side = {
            if case .human = coordinator.white { return .white }
            return .black
        }()
        let gameOver = coordinator.match.status.isGameOver
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            HStack(spacing: Chess.Space.m) {
                Button {
                    pendingConfirm = .draw
                } label: {
                    Label("Draw", systemImage: "circle.lefthalf.filled")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverEffect(.highlight)
                .disabled(gameOver)

                Button(role: .destructive) {
                    pendingConfirm = .resign
                } label: {
                    Label("Resign", systemImage: "flag.fill")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .hoverEffect(.highlight)
                .disabled(gameOver)
                Spacer()
            }

            switch pendingConfirm {
            case .draw:
                InlineConfirm(
                    title: "Agree to a draw?",
                    message: "This will end the game in a draw.",
                    confirmTitle: "Agree to draw",
                    onConfirm: {
                        coordinator.agreeDraw()
                        pendingConfirm = nil
                    },
                    onCancel: { pendingConfirm = nil }
                )
            case .resign:
                InlineConfirm(
                    title: "Resign the game?",
                    message: "Your opponent will be awarded the win.",
                    confirmTitle: "Resign",
                    onConfirm: {
                        coordinator.resign(side: humanSide)
                        pendingConfirm = nil
                    },
                    onCancel: { pendingConfirm = nil }
                )
            case .none:
                EmptyView()
            }
        }
        .animation(.snappy, value: pendingConfirm)
    }
}
