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
    @State private var isAdvancing = false
    @State private var showExitConfirm = false

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
            // One attempt per puzzle (Lichess-style): wrong move OR
            // solve both end the puzzle. The only mid-puzzle control
            // is Hint (which itself counts as a fail and ends the
            // puzzle for rating purposes). No Try-again / Restart.
            if session.status == .solving {
                Button {
                    session.showHint()
                } label: {
                    Label(hintLabel, systemImage: hintIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(session.hintLevel == .fullMove)
            } else if session.status == .solved || session.status == .failed {
                // Category puzzles: jump to the next rail puzzle.
                // Daily puzzle: locked until tomorrow 00:01 local;
                // surface a quiet message instead of a button.
                if session.categoryContext != nil {
                    Button {
                        Task { await advance() }
                    } label: {
                        HStack {
                            if isAdvancing {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isAdvancing ? "Loading…" : "Next puzzle")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Chess.Palette.bronze)
                    .disabled(isAdvancing)
                } else {
                    // No category context = Daily Puzzle. Lichess
                    // ships one new daily puzzle per day; we lock
                    // until 00:01 local of the next day.
                    HStack(spacing: 6) {
                        Image(systemName: "moon.stars")
                            .foregroundStyle(Chess.Palette.bronze)
                        Text("New daily puzzle tomorrow at 00:01.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Button {
                if session.status == .solving {
                    showExitConfirm = true
                } else {
                    Task {
                        appModel.activeSession = nil
                        await dismissImmersiveSpace()
                    }
                }
            } label: {
                Label("Exit puzzle", systemImage: "house.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .confirmationDialog(
                "Exit the puzzle?",
                isPresented: $showExitConfirm,
                titleVisibility: .visible
            ) {
                Button("Exit", role: .destructive) {
                    Task {
                        appModel.activeSession = nil
                        await dismissImmersiveSpace()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your progress on this puzzle will be lost.")
            }
        }
    }

    // MARK: - Next puzzle wiring

    /// Loads the next puzzle in the same category — from the bundled
    /// pool when possible, falling back to `/api/puzzle/next?angle=…`
    /// when the pool is exhausted. Then swaps the active session and
    /// dismisses + re-opens the immersive space so `ChessSceneView`
    /// rebuilds against the new starting position.
    private func advance() async {
        guard !isAdvancing else { return }
        guard let category = session.categoryContext else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        let userRating = appModel.lichess.account?.rating(forPerfKey: "puzzle")
            ?? appModel.lichess.account?.rating(forPerfKey: "rapid")
            ?? 1500

        let puzzle: LichessPuzzle
        do {
            puzzle = try await appModel.bundledPuzzles.ensureNextUnsolved(
                in: category,
                progress: appModel.puzzleProgress,
                userRating: userRating,
                token: appModel.lichess.token
            )
        } catch {
            print("[PuzzleHUD] advance fetch failed: \(error)")
            return
        }

        guard let next = PuzzleSession(puzzle: puzzle) else { return }
        next.onSolvedWithRating = { [progress = appModel.puzzleProgress] id, r, rd in
            progress.recordSolve(puzzleID: id, puzzleRating: r, puzzleRD: rd)
        }
        next.onFailedWithRating = { [progress = appModel.puzzleProgress] id, r, rd in
            progress.recordFail(puzzleID: id, puzzleRating: r, puzzleRD: rd)
        }
        next.categoryContext = session.categoryContext

        appModel.activeSession = .puzzle(next)
        appModel.pendingReopen = true
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        default:
            appModel.activeSession = nil
            appModel.pendingReopen = false
            appModel.immersiveSpaceState = .closed
        }
    }

    private var hintLabel: String {
        switch session.hintLevel {
        case .none:     return "Get a hint"
        case .source:   return "Show the move"
        case .fullMove: return "Hint shown"
        }
    }

    private var hintIcon: String {
        switch session.hintLevel {
        case .none:     return "lightbulb.fill"
        case .source:   return "arrow.up.right.circle.fill"
        case .fullMove: return "checkmark.circle.fill"
        }
    }
}
