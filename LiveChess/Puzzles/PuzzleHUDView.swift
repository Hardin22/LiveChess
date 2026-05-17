import SwiftUI

/// Floating HUD shown next to the immersive 3-D board when the user
/// is solving a puzzle. Mirrors the look of the live-match HUDs:
/// rounded glass panel, ~320 pt wide, with the brand crown header.
@MainActor
struct PuzzleHUDView: View {

    @Bindable var session: PuzzleSession
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            header
            Divider()
            statusSection
            Divider()
            controls
        }
        .padding(Chess.Space.m)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in:
                        RoundedRectangle(cornerRadius: Chess.Radius.card,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: Chess.Space.xs) {
            Image(systemName: "puzzlepiece.fill")
                .foregroundStyle(Chess.Palette.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily Puzzle")
                    .font(.title3.weight(.semibold))
                if let r = session.puzzle.rating {
                    Text("Rating \(r) · \(session.humanSide == .white ? "White to move" : "Black to move")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch session.status {
        case .solving:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: session.isHumanTurn
                          ? "person.fill.questionmark"
                          : "ellipsis")
                    Text(session.isHumanTurn ? "Your move" : "Opponent thinking…")
                        .font(.callout.weight(.medium))
                }
                Text("Move \(session.solveIndex + 1) of \(session.solution.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.puzzle.themes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.puzzle.themes.prefix(4), id: \.self) { t in
                                ChessChip(t.capitalized, tint: Chess.Palette.info)
                            }
                        }
                    }
                }
            }
        case .solved:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Chess.Palette.accent)
                Text("Solved!")
                    .font(.headline)
                    .foregroundStyle(Chess.Palette.accent)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Not the puzzle solution")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Text("Tap Try again to restart from the puzzle position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: Chess.Space.xs) {
            if session.status == .failed {
                Button {
                    session.restart()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.accent)
                .controlSize(.large)
            } else if session.status == .solving {
                Button {
                    session.showHint()
                } label: {
                    Label(session.hintsShown == 0 ? "Hint" : "Hint again",
                          systemImage: "lightbulb.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(role: .destructive) {
                    session.restart()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button(role: .destructive) {
                Task {
                    appModel.activeSession = nil
                    await dismissImmersiveSpace()
                }
            } label: {
                Label("Exit puzzle", systemImage: "house.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }
}
