import SwiftUI

/// Floating HUD shown next to the immersive 3-D board when the user
/// is solving a puzzle. Mirrors the look of the live-match HUDs:
/// rounded glass panel, ~320 pt wide, with the brand crown header.
@MainActor
struct PuzzleHUDView: View {

    @Bindable var session: PuzzleSession
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace)    private var openImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            header
            Divider().overlay(Chess.Palette.bronze.opacity(0.25))
            statusSection
            Divider().overlay(Chess.Palette.bronze.opacity(0.25))
            environmentMenu
            Divider().overlay(Chess.Palette.bronze.opacity(0.25))
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
                        .foregroundStyle(Chess.Palette.bronze)
                    Text("Not the puzzle solution")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Chess.Palette.bronze)
                }
                Text("Tap Try again to restart from the puzzle position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Environment switcher
    //
    // Same dismiss + reopen dance as `LocalMatchHUDView` — sets
    // `pendingReopen` on AppModel so `ChessSceneView.onDisappear`
    // doesn't tear down the puzzle session, then opens a fresh
    // immersive space in the new environment.
    private var environmentMenu: some View {
        Menu {
            ForEach(SceneEnvironment.allCases) { env in
                Button {
                    Task { await switchEnvironment(to: env) }
                } label: {
                    Label(env.displayName, systemImage: env.systemImage)
                    if env == appModel.selectedEnvironment {
                        Image(systemName: "checkmark")
                    }
                }
                .disabled(env == appModel.selectedEnvironment)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mountain.2.fill")
                    .foregroundStyle(Chess.Palette.bronze)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Environment")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(appModel.selectedEnvironment.displayName)
                        .font(.callout.weight(.medium))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func switchEnvironment(to env: SceneEnvironment) async {
        guard env != appModel.selectedEnvironment else { return }
        appModel.selectedEnvironment = env
        appModel.pendingReopen = true
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        default:
            appModel.immersiveSpaceState = .closed
            appModel.pendingReopen = false
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
                .buttonStyle(.bordered)
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

                // Plain bordered (no destructive role) so the button
                // doesn't render red — matches the rest of the app's
                // marble / bronze palette.
                Button {
                    session.restart()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button {
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
