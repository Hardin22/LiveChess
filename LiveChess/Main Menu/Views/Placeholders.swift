// Views/Placeholders.swift
// Secondary-menu screens. Each one drives its own data load from Lichess
// via `LichessService`; nothing here is hardcoded. The file keeps the
// historical `*PlaceholderView` names so `ContentView`'s switch keeps
// resolving without touching the Xcode project.

import SwiftUI

// MARK: - Shared chrome

/// Generic "no content yet" view — used by sections that successfully
/// loaded but came back empty (e.g. account with no games on Lichess).
struct ComingSoonView: View {
    let icon: String
    let title: String
    let description: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(accentColor.gradient)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }
}

/// Wraps a Lichess-gated screen: when the user is signed out it swaps
/// in a sign-in CTA; otherwise it renders the gated content unchanged.
struct LichessGate<Gated: View>: View {
    let icon: String
    let title: String
    let signedOutMessage: String
    let accentColor: Color
    @ViewBuilder let gated: () -> Gated

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.lichess.isSignedIn {
            gated()
        } else {
            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: icon)
                        .font(.system(size: 44))
                        .foregroundStyle(accentColor.gradient)
                }

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(signedOutMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Button {
                    Task { await appModel.lichess.signIn() }
                } label: {
                    Label("Sign in with Lichess", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(minWidth: 240)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(appModel.lichess.status == .signingIn)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassBackgroundEffect()
        }
    }
}

// MARK: - Puzzles
// Categorised browser. Bundled starter pack loaded from
// `LiveChess/Resources/puzzles_starter.json` at init, bucketed by
// theme into `PuzzleCategory`. Each section also exposes a "Load
// more" action that hits `/api/puzzle/next?angle=<theme>` and
// appends results to the in-memory pool for the rest of the session.
// Daily puzzle is fetched separately from `/api/puzzle/daily`.

@Observable
@MainActor
final class PuzzlesViewModel {
    var dailyPuzzle: LichessPuzzle?
    var loadingCategories: Set<PuzzleCategory> = []
    /// Per-category error string, surfaced inline below the section's
    /// puzzle list. Cleared automatically on the next successful fetch
    /// for that category, or when the user taps Retry.
    var errorsByCategory: [PuzzleCategory: String] = [:]
    var isLoading = false
    var errorMessage: String?

    private let service = LichessService()
    private var hasLoadedRemote = false

    /// Loads the daily puzzle from the network. Called from the
    /// view's `.task`. Bundled puzzles live on `appModel.bundledPuzzles`
    /// and load lazily on first access.
    func load(token: String?) async {
        guard !hasLoadedRemote else { return }
        hasLoadedRemote = true
        await service.authenticate(token: token)
        isLoading = true
        defer { isLoading = false }

        do {
            dailyPuzzle = try await service.fetchDailyPuzzle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One press of "Load more" pulls **20 puzzles** in a single
    /// burst — `/api/puzzle/next?angle=<theme>` returns one per call,
    /// so we fire 20 sequentially with a short pause between them.
    /// Results stream into the shared `BundledPuzzleStore` as they
    /// arrive so the UI updates live, not all-at-once at the end.
    /// Stops early on the first hard failure (e.g. 429).
    func loadMore(category: PuzzleCategory,
                  bundle: BundledPuzzleStore,
                  token: String?,
                  batchSize: Int = 20) async {
        guard !loadingCategories.contains(category) else { return }
        loadingCategories.insert(category)
        defer { loadingCategories.remove(category) }
        errorsByCategory[category] = nil
        await service.authenticate(token: token)

        for index in 0..<batchSize {
            if Task.isCancelled { return }
            do {
                let next = try await service.fetchNextPuzzle(angle: category.rawValue)
                bundle.append(next, to: category)
            } catch {
                errorsByCategory[category] = friendlyMessage(for: error)
                return
            }
            if index < batchSize - 1 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Maps URLSession / NSURLError into something the UI can show
    /// without dumping a 200-character internal description. We
    /// special-case the most common Lichess failure (HTTP 429) since
    /// the dev machine + simulator share an IP and the per-IP
    /// rate limit is the easiest way for users to hit a wall.
    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("429") || raw.contains("rate") {
            return "Lichess is rate-limiting this device. Try again in a few minutes."
        }
        if raw.contains("offline") || raw.contains("internet") || raw.contains("network") {
            return "No internet connection."
        }
        return "Couldn’t load a puzzle. Tap Retry."
    }

    // Pool reads (displayedPuzzles, progress) now live on the shared
    // `BundledPuzzleStore` on AppModel — see `BundledPuzzleStore.next-
    // Unsolved(in:progress:userRating:)` and `progress(in:progressStore:)`.
}

struct PuzzlesPlaceholderView: View {
    @Environment(AppModel.self) private var appModel
    @State private var viewModel = PuzzlesViewModel()

    /// User's puzzle rating drives the per-rail ordering: each
    /// section starts from the puzzle closest to (and at-or-above)
    /// this number, then climbs. Falls back to rapid → 1500 when the
    /// user has no puzzle perf yet.
    private var userRating: Int {
        appModel.lichess.account?.rating(forPerfKey: "puzzle")
            ?? appModel.lichess.account?.rating(forPerfKey: "rapid")
            ?? 1500
    }

    private static let gridColumns = [
        GridItem(.adaptive(minimum: 260, maximum: 340),
                 spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ratingHeader
                dailyHero
                LazyVGrid(columns: Self.gridColumns,
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(PuzzleCategory.allCases) { category in
                        categoryBox(category)
                    }
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
        .navigationTitle("Puzzles")
        .task {
            appModel.bundledPuzzles.loadIfNeeded()
            // Seed Glicko-2 from the user's Lichess puzzle rating
            // once, on first visit. After that the local rating
            // evolves independently from in-app solves/fails.
            let perf = appModel.lichess.account?.perfs?["puzzle"]
            appModel.puzzleProgress.seedFromLichess(
                rating: perf?.rating,
                rd: perf?.rd
            )
            await viewModel.load(token: appModel.lichess.token)
        }
        .refreshable {
            await reload()
        }
    }

    /// Hero rating panel — the user's live Glicko-2 puzzle rating,
    /// updated after every solve/fail. Delta chip on the right shows
    /// the last result's effect (e.g. "+8" after a solve, "−12"
    /// after a fail). Same algorithm Lichess uses, so the number
    /// behaves identically to lichess.org's puzzle rating.
    @ViewBuilder
    private var ratingHeader: some View {
        let progress = appModel.puzzleProgress
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Chess.Palette.bronze.opacity(0.22))
                    .frame(width: 56, height: 56)
                Image(systemName: "puzzlepiece.fill")
                    .font(.title2)
                    .foregroundStyle(Chess.Palette.bronze)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Puzzle rating")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(progress.puzzleRatingInt))
                        .font(.system(size: 36,
                                      weight: .bold,
                                      design: .rounded))
                        .monospacedDigit()
                    if let delta = progress.lastRatingDelta, delta != 0 {
                        Text(delta > 0 ? "+\(delta)" : "\(delta)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(delta > 0
                                             ? Color(red: 0.30, green: 0.78, blue: 0.36)
                                             : Color(red: 0.95, green: 0.40, blue: 0.30))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
            }
            Spacer()
        }
        .padding(18)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Chess.Palette.bronze.opacity(0.28), lineWidth: 0.8)
        )
    }

    // MARK: - Daily hero

    @ViewBuilder
    private var dailyHero: some View {
        if appModel.puzzleProgress.isDailyLocked {
            DailyLockedCard(unlockAt: appModel.puzzleProgress.nextDailyUnlock!)
        } else if let daily = viewModel.dailyPuzzle {
            DailyHeroCard(puzzle: daily)
        } else if viewModel.isLoading {
            DailyHeroSkeleton()
        } else if let error = viewModel.errorMessage {
            PuzzlesErrorState(message: error) {
                Task { await reload() }
            }
        }
    }

    // MARK: - Category rail (horizontal deck)

    @ViewBuilder
    private func categoryBox(_ category: PuzzleCategory) -> some View {
        CategoryBox(
            category: category,
            next: appModel.bundledPuzzles.nextUnsolved(
                in: category,
                progress: appModel.puzzleProgress,
                userRating: userRating
            ),
            progress: appModel.bundledPuzzles.progress(
                in: category,
                progressStore: appModel.puzzleProgress
            ),
            isLoading: viewModel.loadingCategories.contains(category),
            error: viewModel.errorsByCategory[category],
            userRating: userRating,
            onLoadMore: {
                Task {
                    await viewModel.loadMore(
                        category: category,
                        bundle: appModel.bundledPuzzles,
                        token: appModel.lichess.token
                    )
                }
            }
        )
    }

    private func reload() async {
        viewModel = PuzzlesViewModel()
        await viewModel.load(token: appModel.lichess.token)
    }
}

// MARK: - Category box (single tappable card in the grid)
//
// Whole box is the primary action — tap anywhere → launches the
// user's next unsolved puzzle in the immersive solver. The earlier
// design had a small "Solve next" pill that was easy to mis-tap, and
// the rest of the row did nothing. Now the entire card is the hit
// target. A small "+20" pill in the top-right batches a fresh fetch
// from Lichess (20 puzzles per press, streamed in).

private struct CategoryBox: View {
    let category: PuzzleCategory
    let next: LichessPuzzle?
    let progress: (solved: Int, total: Int)
    let isLoading: Bool
    let error: String?
    let userRating: Int
    let onLoadMore: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isLaunching = false
    @State private var fetchError: String?

    var body: some View {
        // Outer container is a plain VStack — NOT a Button. Nesting
        // Buttons (an outer 'whole box' Button with an inner Load 20
        // Button) broke visionOS hit-testing: taps on the Solve next
        // area were getting swallowed. Now the box has two distinct
        // Buttons (Solve next + Load 20) that don't interfere.
        VStack(alignment: .leading, spacing: 12) {
            // Category icon. The Load 20 pill that used to live in
            // the top-right corner was removed — bundled pack is
            // enough to play with, and the extra control was noise.
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Chess.Palette.bronze.opacity(0.22))
                        .frame(width: 64, height: 64)
                    Image(systemName: category.systemImage)
                        .font(.title)
                        .foregroundStyle(Chess.Palette.bronze)
                }
                Spacer()
            }

            Text(category.displayName)
                .font(.title3.weight(.bold))
                .lineLimit(1)

            // Solve button is ALWAYS visible — when the bundled pool
            // for this category is exhausted, tapping it falls back
            // to fetching a fresh puzzle from Lichess on the fly
            // (`/api/puzzle/next?angle=<theme>`). The user never sees
            // an "out of puzzles" empty state.
            solveButton(next)
            if let fetchError {
                inlineError(fetchError)
            } else if let error {
                inlineError(error)
            }

            // Show load errors even when a 'next' card is present —
            // before this, an inline error only surfaced once the
            // pool was empty, so users couldn't see why Load 20 had
            // silently failed.
            if let error, next != nil {
                inlineError(error)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func solveButton(_ next: LichessPuzzle?) -> some View {
        Button {
            Task { await launch(next) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Chess.Palette.bronze)
                        .frame(width: 32, height: 32)
                    if isLaunching {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.callout)
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solve")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let next {
                        HStack(spacing: 6) {
                            if let r = next.puzzle.rating {
                                Text("rating \(String(r))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let m = next.puzzle.solution?.count {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.turn.up.right")
                                        .font(.caption2)
                                    Text("\(m) move\(m == 1 ? "" : "s")")
                                        .font(.caption2.monospacedDigit())
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(isLaunching
                             ? "Fetching from Lichess…"
                             : "Tap for a fresh Lichess puzzle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(Chess.Palette.bronze.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Chess.Palette.bronze.opacity(0.40),
                                  lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(isLaunching)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func inlineError(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Launches a puzzle in the immersive solver. When `puzzle` is
    /// nil (bundled pool exhausted for this category), fetches a
    /// fresh one from Lichess via `BundledPuzzleStore.ensureNextUnsolved`
    /// — the user never sees an empty-state.
    ///
    /// Always dismisses any in-flight immersive space first — this
    /// is the only reliable way on visionOS to swap the active
    /// session, since `openImmersiveSpace` is a no-op when one's
    /// already mounted and `ChessSceneView` reads `activeSession`
    /// only at scene-build time.
    private func launch(_ puzzleOrNil: LichessPuzzle?) async {
        guard !isLaunching else { return }
        isLaunching = true
        fetchError = nil
        defer { isLaunching = false }

        let puzzle: LichessPuzzle
        if let local = puzzleOrNil {
            puzzle = local
        } else {
            do {
                puzzle = try await appModel.bundledPuzzles.ensureNextUnsolved(
                    in: category,
                    progress: appModel.puzzleProgress,
                    userRating: userRating,
                    token: appModel.lichess.token
                )
            } catch {
                print("[CategoryBox] ensureNextUnsolved failed: \(error)")
                fetchError = "Couldn’t fetch a puzzle. Tap Solve again."
                return
            }
        }

        guard let session = PuzzleSession(puzzle: puzzle) else {
            print("[CategoryBox] PuzzleSession init returned nil for id=\(puzzle.puzzle.id) — invalid FEN or empty solution?")
            return
        }
        // Glicko-2 path: record both solve and fail with the puzzle's
        // rating so the user's local rating evolves the same way it
        // would on lichess.org (where wrong first move = lose rating).
        session.onSolvedWithRating = { [progress = appModel.puzzleProgress] id, r, rd in
            progress.recordSolve(puzzleID: id, puzzleRating: r, puzzleRD: rd)
        }
        session.onFailedWithRating = { [progress = appModel.puzzleProgress] id, r, rd in
            progress.recordFail(puzzleID: id, puzzleRating: r, puzzleRD: rd)
        }
        session.categoryContext = category

        print("[CategoryBox] launching id=\(puzzle.puzzle.id) category=\(category.rawValue) currentState=\(appModel.immersiveSpaceState)")

        appModel.pendingReopen = true
        appModel.activeSession = .puzzle(session)
        appModel.immersiveSpaceState = .inTransition

        // Always dismiss — no-op if nothing is open. This sidesteps
        // edge cases like `.inTransition` left over from a previous
        // interrupted flow, where the conditional dismiss-when-open
        // path would silently skip the teardown.
        await dismissImmersiveSpace()
        print("[CategoryBox] dismissed; opening fresh immersive...")

        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            print("[CategoryBox] immersive opened OK")
        case .userCancelled:
            print("[CategoryBox] open .userCancelled")
            fallthrough
        case .error:
            print("[CategoryBox] open .error")
            fallthrough
        @unknown default:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
            appModel.pendingReopen = false
        }
    }
}

// MARK: - Daily hero

private struct DailyHeroCard: View {
    let puzzle: LichessPuzzle

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var isLaunching = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            PuzzleMiniBoardView(fen: puzzle.puzzle.fen ?? "",
                                size: 168,
                                lastMove: highlightSquares())
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text("DAILY PUZZLE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Chess.Palette.bronze)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Chess.Palette.bronze.opacity(0.18),
                                in: Capsule())

                HStack(spacing: 6) {
                    Text(puzzle.puzzle.rating.map { String($0) } ?? "—")
                        .font(.title2.monospacedDigit().weight(.bold))
                    Text("rating")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let moves = puzzle.puzzle.solution?.count {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right")
                            .foregroundStyle(.secondary)
                        Text("\(moves) move\(moves == 1 ? "" : "s") to solve")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if !puzzle.puzzle.themes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(puzzle.puzzle.themes.prefix(3), id: \.self) { theme in
                            Text(theme)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.10), in: Capsule())
                        }
                    }
                }

                Button {
                    Task { await launch() }
                } label: {
                    HStack(spacing: 6) {
                        if isLaunching {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Solve in immersive space")
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Chess.Palette.bronze,
                                in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .disabled(isLaunching)
                .padding(.top, 6)
            }

            Spacer()
        }
        .padding(20)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Chess.Palette.bronze.opacity(0.30),
                              lineWidth: 0.8)
        )
    }

    private func highlightSquares() -> ((Int, Int), (Int, Int))? {
        guard let m = puzzle.puzzle.lastMove, m.count >= 4 else { return nil }
        func square(_ s: Substring) -> (Int, Int)? {
            guard s.count == 2,
                  let file = s.first, let rank = s.last else { return nil }
            let col = Int(file.asciiValue ?? 0) - Int(Character("a").asciiValue!)
            let r = (rank.wholeNumberValue ?? 0)
            guard (0...7).contains(col), (1...8).contains(r) else { return nil }
            return (8 - r, col)
        }
        guard let f = square(m.prefix(2)),
              let t = square(m.dropFirst(2).prefix(2)) else { return nil }
        return (f, t)
    }

    private func launch() async {
        guard !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }
        guard let session = PuzzleSession(puzzle: puzzle) else { return }
        // Daily Puzzle in the Puzzles screen: no category context.
        // Solve OR fail locks the slot until tomorrow 00:01.
        session.onSolvedWithRating = { [progress = appModel.puzzleProgress] id, r, rd in
            progress.recordSolve(puzzleID: id, puzzleRating: r, puzzleRD: rd)
            progress.markDailyCompleted()
        }
        session.onFailedWithRating = { [progress = appModel.puzzleProgress] id, r, rd in
            progress.recordFail(puzzleID: id, puzzleRating: r, puzzleRD: rd)
            progress.markDailyCompleted()
        }
        appModel.activeSession = .puzzle(session)
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened: break
        default:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
        }
    }
}

// Daily Puzzle slot, locked until the next 00:01 local. Rendered
// in place of `DailyHeroCard` after the user has solved or failed
// today's daily — one attempt per day, Lichess-style.
private struct DailyLockedCard: View {
    let unlockAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let remaining = max(0, unlockAt.timeIntervalSince(now))
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Chess.Palette.bronze.opacity(0.22))
                    .frame(width: 64, height: 64)
                Image(systemName: "moon.stars.fill")
                    .font(.title)
                    .foregroundStyle(Chess.Palette.bronze)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DAILY PUZZLE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Chess.Palette.bronze)
                Text("Solved for today")
                    .font(.title3.weight(.semibold))
                Text("Next puzzle in \(Self.format(remaining)) — at \(Self.unlockTimeString(unlockAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Chess.Palette.bronze.opacity(0.28),
                              lineWidth: 0.8)
        )
    }

    private static func format(_ secs: TimeInterval) -> String {
        let total = Int(secs.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m"      }
        return "moments"
    }

    private static func unlockTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

private struct DailyHeroSkeleton: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.10))
                .frame(width: 168, height: 168)
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(.white.opacity(0.10)).frame(width: 120, height: 14)
                Capsule().fill(.white.opacity(0.10)).frame(width: 180, height: 18)
                Capsule().fill(.white.opacity(0.10)).frame(width: 160, height: 12)
            }
            Spacer()
        }
        .padding(20)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(0.7 + 0.3 * Double(sin(Double(phase))))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}


private struct PuzzlesErrorState: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load puzzles")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Game Review
// Real data: `/api/games/user/{username}` filtered to games that have
// Stockfish analysis attached.

@Observable
@MainActor
final class GameReviewViewModel {
    var games: [LichessGame] = []
    var isLoading = false
    var errorMessage: String?

    private let service = LichessService()
    private var hasLoadedFor: String?

    func load(username: String, token: String?) async {
        guard hasLoadedFor != username else { return }
        hasLoadedFor = username
        await service.authenticate(token: token)
        isLoading = true
        defer { isLoading = false }
        do {
            games = try await service.fetchRecentGames(
                username: username,
                count: 50,
                withAnalysis: true,
                withOpening: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func analyzedGames(for username: String) -> [LichessGame] {
        // Require both the accuracy summary AND the per-ply analysis
        // array. Lichess will give some games one without the other —
        // accuracy comes from their cheap pass, the analysis array
        // only lands when someone requested a deep computer analysis
        // on the website. Showing summary-only games here makes them
        // look reviewable, but the immersive HUD then has nothing to
        // classify against.
        games.filter { game in
            guard game.accuracy(for: username) != nil else { return false }
            guard let analysis = game.analysis, !analysis.isEmpty else {
                return false
            }
            return true
        }
    }
}

struct GameReviewPlaceholderView: View {
    @Environment(AppModel.self) private var appModel
    @State private var viewModel = GameReviewViewModel()

    var body: some View {
        LichessGate(
            icon: "magnifyingglass.circle.fill",
            title: "Game Review",
            signedOutMessage: "Sign in with Lichess to review your games with Stockfish-powered analysis.",
            accentColor: .blue
        ) {
            content
        }
        .navigationTitle("Game Review")
        .task {
            if let username = appModel.lichess.account?.username {
                await viewModel.load(username: username, token: appModel.lichess.token)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let username = appModel.lichess.account?.username ?? ""
        let analyzed = viewModel.analyzedGames(for: username)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Analyzed Games", subtitle: "Games with Stockfish analysis from Lichess")

                if viewModel.isLoading && analyzed.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { _ in GameRowSkeleton() }
                    }
                } else if let error = viewModel.errorMessage, analyzed.isEmpty {
                    ErrorStateCard(message: error)
                } else if analyzed.isEmpty {
                    EmptyStateCard(
                        icon: "magnifyingglass.circle.fill",
                        title: "No analyzed games yet",
                        message: "Request analysis on a game in Lichess to see it here."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(analyzed) { game in
                            GameRowView(game: game, username: username)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }
}

// MARK: - History
// Real data: `/api/games/user/{username}`, full list (no analysis
// filter), with a search field.

@Observable
@MainActor
final class HistoryViewModel {
    var games: [LichessGame] = []
    var isLoading = false
    var errorMessage: String?
    var searchText: String = ""

    private let service = LichessService()
    private var hasLoadedFor: String?

    func load(username: String, token: String?) async {
        guard hasLoadedFor != username else { return }
        hasLoadedFor = username
        await service.authenticate(token: token)
        isLoading = true
        defer { isLoading = false }
        do {
            games = try await service.fetchRecentGames(
                username: username,
                count: 50,
                withAnalysis: false,
                withOpening: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func filtered(for username: String) -> [LichessGame] {
        guard !searchText.isEmpty else { return games }
        return games.filter { game in
            game.opponent(for: username).localizedCaseInsensitiveContains(searchText)
                || (game.opening?.name?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}

struct HistoryPlaceholderView: View {
    @Environment(AppModel.self) private var appModel
    @State private var viewModel = HistoryViewModel()

    var body: some View {
        LichessGate(
            icon: "clock.fill",
            title: "Game History",
            signedOutMessage: "Sign in with Lichess to browse your past games.",
            accentColor: .orange
        ) {
            content
        }
        .navigationTitle("History")
        .task {
            if let username = appModel.lichess.account?.username {
                await viewModel.load(username: username, token: appModel.lichess.token)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let username = appModel.lichess.account?.username ?? ""
        let games = viewModel.filtered(for: username)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionHeader(title: "Game History", subtitle: "Your most recent \(viewModel.games.count) games from Lichess")
                    Spacer()
                }

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search opponent or opening", text: Binding(
                        get: { viewModel.searchText },
                        set: { viewModel.searchText = $0 }
                    ))
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                if viewModel.isLoading && games.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(0..<8, id: \.self) { _ in GameRowSkeleton() }
                    }
                } else if let error = viewModel.errorMessage, games.isEmpty {
                    ErrorStateCard(message: error)
                } else if games.isEmpty {
                    EmptyStateCard(
                        icon: "clock.fill",
                        title: viewModel.searchText.isEmpty ? "No games yet" : "No matching games",
                        message: viewModel.searchText.isEmpty
                            ? "Play a game on Lichess to see it here."
                            : "Try a different opponent name or opening."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(games) { game in
                            GameRowView(game: game, username: username)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }
}

// MARK: - Profile (unchanged from before)

struct ProfilePlaceholderView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        LichessGate(
            icon: "person.fill",
            title: "Profile",
            signedOutMessage: "Sign in with Lichess to see your rating history, ratings across speeds, and stats.",
            accentColor: .teal
        ) {
            if let account = appModel.lichess.account {
                ProfileCardView(account: account)
            } else {
                ComingSoonView(
                    icon: "person.fill",
                    title: "Profile",
                    description: "Loading your Lichess profile…",
                    accentColor: .teal
                )
            }
        }
        .navigationTitle("Profile")
    }
}

private struct ProfileCardView: View {
    let account: LichessAccount
    @Environment(AppModel.self) private var appModel
    @State private var showSignOutConfirm = false

    // Single source of truth for which perfs we surface lives on
    // `LichessAccount.displayedPerfKeys`. Bullet/Blitz are excluded
    // there because we can't play them in this app, so showing those
    // ratings would be misleading clutter.
    private var displayedRows: [LichessAccount.RatingRow] {
        account.displayedRatingRows
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.teal.gradient)
                            .frame(width: 96, height: 96)
                        Text(String(account.username.prefix(1)).uppercased())
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 6) {
                        if let title = account.title {
                            Text(title)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        Text(account.username)
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.top, 24)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                          spacing: 12) {
                    ForEach(displayedRows) { row in
                        ratingChip(row: row)
                    }
                }
                .padding(.horizontal, 24)

                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Label("Sign out of Lichess", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: 280)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .padding(.top, 12)
                .confirmationDialog(
                    "Sign out of Lichess?",
                    isPresented: $showSignOutConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) {
                        Task { await appModel.lichess.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll need to sign in again to play rated games or sync puzzles.")
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func ratingChip(row: LichessAccount.RatingRow) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: row.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ratingText(for: row))
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
            Text(row.games.map { "\($0) games" } ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func ratingText(for row: LichessAccount.RatingRow) -> String {
        guard let r = row.rating else { return "—" }
        return String(r)   // ungrouped — chess convention ("1500" not "1,500")
    }
}

// MARK: - Settings & Notifications (still placeholders)

/// Real Settings screen — chess.com-style two-column layout with a
/// left section list and a right detail pane.
///
/// Sections are limited to features the app actually has. A fake
/// "Sounds" toggle that doesn't wire to a real SoundController would
/// be worse than no toggle — so omitted sections (Sounds, Coach,
/// Membership, Notifications, Language) reflect missing app features,
/// not missing settings UI.
struct SettingsPlaceholderView: View {
    @Environment(AppModel.self) private var appModel

    enum Section: String, CaseIterable, Identifiable {
        case account, gameplay, boardAndPieces, environment, legal, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .account:        return "Account"
            case .gameplay:       return "Gameplay"
            case .boardAndPieces: return "Board & Pieces"
            case .environment:    return "Environment"
            case .legal:          return "Legal"
            case .about:          return "About"
            }
        }
        var systemImage: String {
            switch self {
            case .account:        return "person.crop.circle.fill"
            case .gameplay:       return "flag.checkered"
            case .boardAndPieces: return "checkerboard.rectangle"
            case .environment:    return "mountain.2.fill"
            case .legal:          return "hand.raised.fill"
            case .about:          return "info.circle.fill"
            }
        }
        var subtitle: String {
            switch self {
            case .account:        return "Lichess sign-in and account info."
            case .gameplay:       return "Default color, Stockfish strength, and thinking time."
            case .boardAndPieces: return "Piece set and board surface for the 3D scene."
            case .environment:    return "Where the board lives when you open an immersive match."
            case .legal:          return "Privacy Policy and Terms of Service."
            case .about:          return "Version, credits, and the platforms we build on."
            }
        }
    }

    @State private var selection: Section = .account
    @State private var presentedLegal: LegalDocument?
    @State private var settingsPreviewSide: Side = .white
    @State private var settingsPreviewKind: PieceKind = .king

    var body: some View {
        @Bindable var appModel = appModel

        HStack(alignment: .top, spacing: Chess.Space.l) {
            sectionRail
                .frame(width: 240)

            ScrollView {
                detailPane(appModel: appModel)
                    .padding(.bottom, Chess.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .padding(Chess.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedLegal) { doc in
            LegalDocumentSheet(document: doc)
        }
    }

    // MARK: - Section rail (left column)

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            BrandMark(.wordmark(size: 26))
            Text("Settings")
                .font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                ForEach(Section.allCases) { sec in
                    sectionRow(sec)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func sectionRow(_ sec: Section) -> some View {
        let isSelected = sec == selection
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selection = sec
            }
        } label: {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: sec.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Chess.Palette.bronze)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous)
                            .fill(isSelected ? Chess.Palette.bronze.opacity(0.18) : .white.opacity(0.07))
                    )
                Text(sec.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, Chess.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(
                              LinearGradient(
                                  colors: [
                                      Chess.Palette.cream.opacity(0.24),
                                      Chess.Palette.bronze.opacity(0.10)
                                  ],
                                  startPoint: .topLeading,
                                  endPoint: .bottomTrailing
                              )
                          )
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.45)
                                  : .white.opacity(0.08),
                                  lineWidth: isSelected ? 1 : 0.5)
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: - Detail pane (right column)

    @ViewBuilder
    private func detailPane(appModel: AppModel) -> some View {
        VStack(alignment: .leading, spacing: Chess.Space.l) {
            paneHeader(selection)
            switch selection {
            case .account:        accountPane
            case .gameplay:       gameplayPane(appModel: appModel)
            case .boardAndPieces: boardAndPiecesPane
            case .environment:    environmentPane(appModel: appModel)
            case .legal:          legalPane
            case .about:          aboutPane
            }
        }
        .frame(maxWidth: 720, alignment: .topLeading)
    }

    private func paneHeader(_ sec: Section) -> some View {
        HStack(alignment: .center, spacing: Chess.Space.m) {
            Image(systemName: sec.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Chess.Palette.bronze)
                .frame(width: 52, height: 52)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                        .strokeBorder(Chess.Palette.bronze.opacity(0.28), lineWidth: 0.75)
                        .allowsHitTesting(false)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(sec.title)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .foregroundStyle(Chess.Palette.accent)
                Text(sec.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pane — Account

    @ViewBuilder
    private var accountPane: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                if appModel.lichess.isSignedIn {
                    HStack(spacing: Chess.Space.s) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Chess.Palette.bronze)
                            .frame(width: 48, height: 48)
                            .background(.thinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Chess.Palette.bronze.opacity(0.28), lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appModel.lichess.account?.username ?? "Signed in")
                                .font(.title3.weight(.semibold))
                            Text("Lichess connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ChessChip("Online", icon: "checkmark.circle.fill", tint: Chess.Palette.bronze)
                    }
                    Divider().overlay(Chess.Palette.bronze.opacity(0.25))
                    if let perfs = appModel.lichess.account?.perfs {
                        let popular = ["rapid", "classical"]
                            .compactMap { key -> (String, Int)? in
                                guard let r = perfs[key]?.rating else { return nil }
                                return (key.capitalized, r)
                            }
                        if !popular.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ratings")
                                    .font(Chess.Typography.eyebrow())
                                    .foregroundStyle(.secondary)
                                HStack(spacing: Chess.Space.s) {
                                    ForEach(popular, id: \.0) { (label, rating) in
                                        ratingTile(label: label, rating: rating)
                                    }
                                }
                            }
                            Divider().overlay(Chess.Palette.bronze.opacity(0.25))
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Sign out") {
                            Task { await appModel.lichess.signOut() }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Chess.Space.s) {
                        HStack(spacing: Chess.Space.s) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 48, height: 48)
                                .background(.thinMaterial, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not signed in")
                                    .font(.title3.weight(.semibold))
                                Text("Connect Lichess for online play, ratings, and cloud-analysed game review.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            Task { await appModel.lichess.signIn() }
                        } label: {
                            Label("Sign in with Lichess", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Chess.Palette.bronze)
                        .controlSize(.large)
                    }
                }
            }
        }
    }

    // MARK: Pane — Gameplay

    @ViewBuilder
    private func gameplayPane(appModel: AppModel) -> some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                // Default color
                VStack(alignment: .leading, spacing: 6) {
                    settingsControlHeader(
                        title: "Default color",
                        value: colorLabel(appModel.matchSettings.humanColor),
                        icon: "circle.lefthalf.filled"
                    )
                    Picker("Default color", selection: Binding(
                        get: { appModel.matchSettings.humanColor },
                        set: { appModel.matchSettings.humanColor = $0 }
                    )) {
                        Text("White").tag(MatchSettings.HumanColor.white)
                        Text("Black").tag(MatchSettings.HumanColor.black)
                        Text("Random").tag(MatchSettings.HumanColor.random)
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Chess.Palette.bronze.opacity(0.25))

                // Default Stockfish skill (0–20)
                VStack(alignment: .leading, spacing: 6) {
                    settingsControlHeader(
                        title: "Stockfish skill",
                        value: "\(appModel.matchSettings.aiSettings.skillLevel) / \(AISettings.maxSkillLevel)",
                        icon: "brain.head.profile"
                    )
                    Slider(
                        value: Binding(
                            get: { Double(appModel.matchSettings.aiSettings.skillLevel) },
                            set: { appModel.matchSettings.aiSettings.skillLevel = Int($0) }
                        ),
                        in: Double(AISettings.minSkillLevel)...Double(AISettings.maxSkillLevel),
                        step: 1
                    )
                    .tint(Chess.Palette.bronze)
                    Text("0 plays nearly random moves; 20 is full strength.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().overlay(Chess.Palette.bronze.opacity(0.25))

                // Default thinking time
                VStack(alignment: .leading, spacing: 6) {
                    let seconds = thinkingTimeSeconds(appModel.matchSettings.aiSettings.thinkingTime)
                    settingsControlHeader(
                        title: "Thinking time",
                        value: "\(String(format: "%.1f", seconds))s per move",
                        icon: "timer"
                    )
                    Slider(
                        value: Binding(
                            get: { seconds },
                            set: { appModel.matchSettings.aiSettings.thinkingTime = .seconds($0) }
                        ),
                        in: 0.2...5.0, step: 0.1
                    )
                    .tint(Chess.Palette.bronze)
                    Text("Caps how long Stockfish spends on each move.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Pane — Board & Pieces

    @ViewBuilder
    private var boardAndPiecesPane: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            ChessCard(.standard) {
                VStack(alignment: .leading, spacing: Chess.Space.m) {
                    HStack(alignment: .top, spacing: Chess.Space.s) {
                        Image(systemName: "paintbrush.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Chess.Palette.bronze)
                            .frame(width: 48, height: 48)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                                    .strokeBorder(Chess.Palette.bronze.opacity(0.28), lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appModel.pieceCustomization.current.preset.displayName)
                                .font(.title3.weight(.semibold))
                            Text("Compare the default set with the custom set before choosing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        previewSelectorControls
                    }

                    Divider().overlay(Chess.Palette.bronze.opacity(0.25))

                    HStack(alignment: .top, spacing: Chess.Space.s) {
                        comparisonPreviewTile(
                            title: "Default",
                            subtitle: PieceMaterial.default.preset.displayName,
                            material: .default
                        )
                        comparisonPreviewTile(
                            title: "Custom",
                            subtitle: appModel.pieceCustomization.current.preset.displayName,
                            material: appModel.pieceCustomization.current
                        )
                    }
                }
            }

            settingsSubcard(title: "Piece material", icon: "circle.grid.2x2.fill") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 190), spacing: Chess.Space.s),
                        GridItem(.flexible(minimum: 190), spacing: Chess.Space.s)
                    ],
                    spacing: Chess.Space.s
                ) {
                    ForEach(PieceMaterial.Preset.allCases) { preset in
                        settingsPresetButton(preset)
                    }
                }

                if appModel.pieceCustomization.current.preset == .wood {
                    Divider().overlay(Chess.Palette.bronze.opacity(0.20))
                    HStack(alignment: .top, spacing: Chess.Space.s) {
                        woodPicker(
                            title: "White pieces",
                            selected: appModel.pieceCustomization.current.whitePieceWood,
                            onPick: { appModel.pieceCustomization.current.whitePieceWood = $0 }
                        )
                        woodPicker(
                            title: "Black pieces",
                            selected: appModel.pieceCustomization.current.blackPieceWood,
                            onPick: { appModel.pieceCustomization.current.blackPieceWood = $0 }
                        )
                    }
                }
            }

            settingsSubcard(title: "Piece colours", icon: "eyedropper.full") {
                HStack(alignment: .top, spacing: Chess.Space.s) {
                    settingsColorPicker(
                        title: "White pieces",
                        binding: pieceColorBinding(\.whiteColor)
                    )
                    settingsColorPicker(
                        title: "Black pieces",
                        binding: pieceColorBinding(\.blackColor)
                    )
                }
            }

            settingsSubcard(title: "Board surface", icon: "checkerboard.rectangle") {
                HStack(alignment: .top, spacing: Chess.Space.m) {
                    BoardPreviewView(material: appModel.pieceCustomization.current)
                        .frame(width: 170, height: 170)
                        .padding(Chess.Space.s)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))

                    VStack(alignment: .leading, spacing: Chess.Space.s) {
                        boardSurfaceControls
                        Divider().overlay(Chess.Palette.bronze.opacity(0.20))
                        HStack(alignment: .top, spacing: Chess.Space.s) {
                            settingsColorPicker(
                                title: "Light squares",
                                binding: pieceColorBinding(\.lightSquareColor)
                            )
                            settingsColorPicker(
                                title: "Dark squares",
                                binding: pieceColorBinding(\.darkSquareColor)
                            )
                            settingsColorPicker(
                                title: "Frame",
                                binding: pieceColorBinding(\.frameColor)
                            )
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    appModel.pieceCustomization.resetToDefault()
                } label: {
                    Label("Reset to default", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var previewSelectorControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                previewSideButton(.white)
                previewSideButton(.black)
            }
            Menu {
                ForEach(PieceKind.allCases, id: \.self) { kind in
                    Button(pieceKindName(kind)) {
                        settingsPreviewKind = kind
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(pieceKindName(settingsPreviewKind))
                        .font(.callout.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, Chess.Space.s)
                .frame(width: 230, height: 36)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
            }
        }
    }

    private func comparisonPreviewTile(title: String, subtitle: String, material: PieceMaterial) -> some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text("\(subtitle) · \(pieceSideName(settingsPreviewSide))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            PiecePreviewView(
                material: material,
                previewSide: $settingsPreviewSide,
                previewKind: $settingsPreviewKind
            )
            .clipShape(RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        }
        .padding(Chess.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    private func previewSideButton(_ side: Side) -> some View {
        let isSelected = settingsPreviewSide == side
        let color: Color = {
            switch side {
            case .white:
                return appModel.pieceCustomization.current.whiteColor.swiftUI
            case .black:
                return appModel.pieceCustomization.current.blackColor.swiftUI
            }
        }()

        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                settingsPreviewSide = side
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
                Text(pieceSideName(side))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(width: 112, height: 36)
            .background(isSelected ? Chess.Palette.bronze.opacity(0.24) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous)
                    .strokeBorder(isSelected ? Chess.Palette.bronze.opacity(0.55) : .white.opacity(0.09), lineWidth: isSelected ? 1 : 0.5)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private func settingsSubcard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                HStack(spacing: Chess.Space.s) {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Chess.Palette.bronze)
                        .frame(width: 34, height: 34)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
                    Text(title)
                        .font(Chess.Typography.sectionTitle())
                    Spacer()
                }
                content()
            }
        }
    }

    private func settingsPresetButton(_ preset: PieceMaterial.Preset) -> some View {
        let current = appModel.pieceCustomization.current
        let isSelected = current.preset == preset

        return Button {
            var next = current
            let pair = preset.defaultPair
            next.preset = preset
            next.whiteColor = pair.white
            next.blackColor = pair.black
            appModel.pieceCustomization.current = next
        } label: {
            HStack(spacing: Chess.Space.s) {
                presetSwatch(preset)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(materialHint(for: preset))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Chess.Palette.bronze)
                }
            }
            .padding(Chess.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? .white.opacity(0.095) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected ? Chess.Palette.bronze.opacity(0.35) : .white.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private func settingsColorPicker(title: String, binding: Binding<Color>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                ColorPicker("", selection: binding, supportsOpacity: false)
                    .labelsHidden()
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(binding.wrappedValue)
                    .frame(height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Chess.Space.s)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
    }

    private var boardSurfaceControls: some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Squares")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                boardMaterialPicker(
                    selected: appModel.pieceCustomization.current.squareMaterial,
                    onPick: { appModel.pieceCustomization.current.squareMaterial = $0 }
                )
                if appModel.pieceCustomization.current.squareMaterial == .wood {
                    HStack(alignment: .top, spacing: Chess.Space.s) {
                        woodPicker(
                            title: "Light wood",
                            selected: appModel.pieceCustomization.current.lightSquareWood,
                            onPick: { appModel.pieceCustomization.current.lightSquareWood = $0 }
                        )
                        woodPicker(
                            title: "Dark wood",
                            selected: appModel.pieceCustomization.current.darkSquareWood,
                            onPick: { appModel.pieceCustomization.current.darkSquareWood = $0 }
                        )
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Frame")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                boardMaterialPicker(
                    selected: appModel.pieceCustomization.current.frameMaterial,
                    onPick: { appModel.pieceCustomization.current.frameMaterial = $0 }
                )
                if appModel.pieceCustomization.current.frameMaterial == .wood {
                    woodPicker(
                        title: "Frame wood",
                        selected: appModel.pieceCustomization.current.frameWood,
                        onPick: { appModel.pieceCustomization.current.frameWood = $0 }
                    )
                }
            }
        }
    }

    private func boardMaterialPicker(
        selected: BoardMaterial,
        onPick: @escaping (BoardMaterial) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(BoardMaterial.allCases) { material in
                let isSelected = material == selected
                Button {
                    onPick(material)
                } label: {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(material.displayName)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(isSelected ? Chess.Palette.bronze.opacity(0.22) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous)
                            .strokeBorder(isSelected ? Chess.Palette.bronze.opacity(0.42) : .white.opacity(0.08), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func woodPicker(
        title: String,
        selected: WoodType,
        onPick: @escaping (WoodType) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(WoodType.allCases) { wood in
                    let isSelected = wood == selected
                    Button {
                        onPick(wood)
                    } label: {
                        Text(wood.displayName)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 9)
                            .background(isSelected ? Chess.Palette.bronze.opacity(0.22) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous)
                                    .strokeBorder(isSelected ? Chess.Palette.bronze.opacity(0.42) : .white.opacity(0.08), lineWidth: 0.5)
                                    .allowsHitTesting(false)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pieceColorBinding(_ keyPath: WritableKeyPath<PieceMaterial, PieceColor>) -> Binding<Color> {
        Binding(
            get: { appModel.pieceCustomization.current[keyPath: keyPath].swiftUI },
            set: { appModel.pieceCustomization.current[keyPath: keyPath] = PieceColor($0) }
        )
    }

    private func presetSwatch(_ preset: PieceMaterial.Preset) -> some View {
        Circle()
            .fill(presetFill(preset))
            .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 0.5))
            .overlay(
                Circle()
                    .trim(from: 0.55, to: 0.86)
                    .stroke(.white.opacity(0.45), lineWidth: 1.1)
                    .padding(2)
            )
    }

    private func presetFill(_ preset: PieceMaterial.Preset) -> AnyShapeStyle {
        switch preset {
        case .plasticMatte:
            return AnyShapeStyle(Color(red: 0.92, green: 0.92, blue: 0.92))
        case .plasticGlossy:
            return AnyShapeStyle(LinearGradient(colors: [Color.white, Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .lacquered:
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.78, green: 0.16, blue: 0.18), Color(red: 0.45, green: 0.05, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .polishedMetal:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .brushedMetal:
            return AnyShapeStyle(Color(white: 0.70))
        case .ceramic:
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.97, green: 0.96, blue: 0.93), Color(red: 0.85, green: 0.83, blue: 0.78)], startPoint: .top, endPoint: .bottom))
        case .pearl:
            return AnyShapeStyle(AngularGradient(colors: [.pink.opacity(0.6), .cyan.opacity(0.4), .white, .yellow.opacity(0.5), .pink.opacity(0.6)], center: .center))
        case .glass:
            return AnyShapeStyle(LinearGradient(colors: [Color.cyan.opacity(0.35), Color.blue.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .wood:
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.18), Color(red: 0.32, green: 0.18, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .marble:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func materialHint(for preset: PieceMaterial.Preset) -> String {
        switch preset {
        case .plasticMatte: return "Soft, low shine"
        case .plasticGlossy: return "Classic glossy set"
        case .lacquered: return "Deep polished finish"
        case .polishedMetal: return "Bright reflective metal"
        case .brushedMetal: return "Muted satin metal"
        case .ceramic: return "Smooth porcelain look"
        case .pearl: return "Subtle iridescent sheen"
        case .glass: return "Transparent tinted glass"
        case .wood: return "Natural textured wood"
        case .marble: return "Stone with veining"
        }
    }

    private func pieceKindName(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: return "Pawn"
        case .knight: return "Knight"
        case .bishop: return "Bishop"
        case .rook: return "Rook"
        case .queen: return "Queen"
        case .king: return "King"
        }
    }

    private func pieceSideName(_ side: Side) -> String {
        switch side {
        case .white: return "White"
        case .black: return "Black"
        }
    }

    // MARK: Pane — Environment

    @ViewBuilder
    private func environmentPane(appModel: AppModel) -> some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                Text("Choose the default backdrop when you open an immersive match. You can still switch mid-match from any game HUD.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider().overlay(Chess.Palette.bronze.opacity(0.25))
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: Chess.Space.s),
                        GridItem(.flexible(), spacing: Chess.Space.s)
                    ],
                    spacing: Chess.Space.s
                ) {
                    ForEach(SceneEnvironment.allCases) { env in
                        environmentTile(env, appModel: appModel)
                    }
                }
            }
        }
    }

    private func environmentTile(_ env: SceneEnvironment, appModel: AppModel) -> some View {
        let isSelected = appModel.selectedEnvironment == env
        return Button { appModel.selectedEnvironment = env } label: {
            VStack(spacing: 4) {
                Image(systemName: env.systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Chess.Palette.bronze)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(env.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, Chess.Space.xs)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(
                              LinearGradient(
                                  colors: [
                                      Chess.Palette.cream.opacity(0.22),
                                      Chess.Palette.bronze.opacity(0.09)
                                  ],
                                  startPoint: .topLeading,
                                  endPoint: .bottomTrailing
                              )
                          )
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.55)
                                  : .white.opacity(0.08),
                                  lineWidth: isSelected ? 1.2 : 0.5)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Chess.Palette.bronze)
                        .padding(Chess.Space.xs)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(Text(env.displayName))
        .accessibilityHint(Text(environmentSubtitle(env)))
    }

    // MARK: Pane — Legal

    @ViewBuilder
    private var legalPane: some View {
        ChessCard(.standard) {
            VStack(spacing: 0) {
                legalRow(
                    title: "Privacy Policy",
                    subtitle: "What data Chess+ collects and how it's used.",
                    icon: "hand.raised.fill"
                ) { presentedLegal = .privacy }

                Divider().overlay(.white.opacity(0.08))
                    .padding(.vertical, 2)

                legalRow(
                    title: "Terms & Conditions",
                    subtitle: "The rules for using Chess+ and our services.",
                    icon: "doc.text.fill"
                ) { presentedLegal = .terms }
            }
        }
    }

    private func legalRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Chess.Palette.bronze)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous)
                            .strokeBorder(Chess.Palette.bronze.opacity(0.22), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Chess.Space.s)
            .padding(.horizontal, Chess.Space.s)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: Pane — About

    @ViewBuilder
    private var aboutPane: some View {
        VStack(spacing: Chess.Space.m) {
            ChessCard(.standard) {
                VStack(alignment: .leading, spacing: Chess.Space.s) {
                    settingRow("Version", value: Self.appVersionString, icon: "info.circle.fill")
                    settingRow("Platform", value: "visionOS — built on RealityKit + Stockfish", icon: "visionpro")
                }
            }
        }
    }

    // MARK: Helpers

    private func ratingTile(label: String, rating: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(rating)")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Chess.Palette.bronze)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Chess.Space.s)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.13), Chess.Palette.cream.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    private func settingsControlHeader(title: String, value: String, icon: String) -> some View {
        HStack(spacing: Chess.Space.s) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Chess.Palette.bronze)
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
            Text(title)
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Chess.Palette.bronze)
        }
    }

    private func colorLabel(_ color: MatchSettings.HumanColor) -> String {
        switch color {
        case .white: return "White"
        case .black: return "Black"
        case .random: return "Random"
        }
    }

    private func materialSwatch(_ color: Color, size: CGFloat = 28, isSelected: Bool = false) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(isSelected ? Chess.Palette.bronze.opacity(0.85) : .white.opacity(0.42), lineWidth: isSelected ? 2 : 1)
                    .allowsHitTesting(false)
            )
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: max(8, size * 0.42), weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
    }

    private func materialPreviewTile(title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                        .allowsHitTesting(false)
                )
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Chess.Space.s)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
    }

    private func environmentSubtitle(_ env: SceneEnvironment) -> String {
        switch env {
        case .ar: return "Passthrough with table placement"
        case .dwarvenHall: return "Warm stone hall with dramatic lighting"
        case .balcony: return "Open-air board with a softer scene"
        case .auditoriumStage: return "Presentation stage for focused play"
        }
    }

    private func settingRow(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: Chess.Space.s) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Chess.Palette.bronze.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Chess.Space.s)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    private func aboutLink(_ title: String, subtitle: String, url: String, icon: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Chess.Palette.bronze.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(Chess.Space.s)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private func thinkingTimeSeconds(_ d: Duration) -> Double {
        let components = d.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static var appVersionString: String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (build \(build))"
    }
}

// MARK: - Legal documents

/// Which legal document is being shown in the modal sheet.
enum LegalDocument: String, Identifiable {
    case privacy, terms
    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "Privacy Policy"
        case .terms:   return "Terms & Conditions"
        }
    }

    var icon: String {
        switch self {
        case .privacy: return "hand.raised.fill"
        case .terms:   return "doc.text.fill"
        }
    }

    var lastUpdated: String {
        // Update when the body copy below changes.
        "Last updated: May 19, 2026"
    }
}

/// Modal sheet that presents the privacy / terms body copy.
///
/// The bodies live in `LegalDocument.body(_:)` as plain Markdown-free
/// text broken into `(heading, paragraph)` pairs so we can render them
/// with consistent typography. Translate to actual approved legal copy
/// before App Store submission — what's here is a reasonable starting
/// point that reflects how the app currently works (Lichess auth,
/// Stockfish locally, no analytics).
private struct LegalDocumentSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Chess.Space.l) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: Chess.Space.s) {
                            Image(systemName: document.icon)
                                .font(.title2)
                                .foregroundStyle(Chess.Palette.bronze)
                            Text(document.title)
                                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        }
                        Text(document.lastUpdated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(LegalContent.sections(for: document).enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.heading)
                                .font(.headline)
                                .foregroundStyle(Chess.Palette.accent)
                            Text(section.body)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Chess.Space.l)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
    }
}

/// Static body copy for the legal documents. Replace these strings with
/// the approved copy from your lawyer / App Store submission. The
/// structure ([Section]) lets us add a new section without touching the
/// sheet view.
private enum LegalContent {
    struct Section {
        let heading: String
        let body: String
    }

    static func sections(for doc: LegalDocument) -> [Section] {
        switch doc {
        case .privacy: return privacy
        case .terms:   return terms
        }
    }

    private static let privacy: [Section] = [
        Section(
            heading: "Overview",
            body: """
            Chess+ is designed to keep your data on your device. We do not run our own analytics, advertising, or tracking. The only data that leaves your Apple Vision Pro is what you explicitly send to a third-party service (such as Lichess) when you choose to sign in or play an online game.
            """
        ),
        Section(
            heading: "Information we collect",
            body: """
            • Local preferences. Your gameplay defaults (preferred color, Stockfish skill, thinking time), board and piece selections, and chosen environment are stored locally on your device.

            • Lichess account. If you sign in with Lichess, an OAuth access token issued by Lichess is stored in the system keychain. We use it only to talk to Lichess on your behalf.

            • Match data. Games you play locally never leave your device. Games you play on Lichess live in your Lichess account under their terms.
            """
        ),
        Section(
            heading: "What we don't do",
            body: """
            • No advertising. Chess+ does not show ads and does not share data with advertisers.

            • No tracking. We do not use third-party analytics SDKs or fingerprinting.

            • No selling. We do not sell or rent any data to third parties.
            """
        ),
        Section(
            heading: "Third-party services",
            body: """
            When you choose to connect to them, the following services receive data directly from your device under their own privacy policies:

            • Lichess (lichess.org) — authentication, online play, profile, and cloud game analysis.

            • Apple — App Store, in-app purchase, and basic crash diagnostics, governed by Apple's privacy policy.

            Stockfish runs locally on your device and does not send moves anywhere.
            """
        ),
        Section(
            heading: "Children",
            body: """
            Chess+ is not directed at children under 13. If you believe a child has provided personal data through Chess+, contact us and we will delete it.
            """
        ),
        Section(
            heading: "Your rights",
            body: """
            You can sign out of Lichess from Settings → Account at any time. This removes the stored access token from the keychain on this device. To delete your Lichess account itself, use lichess.org.
            """
        ),
        Section(
            heading: "Changes",
            body: """
            If we change this policy, we will update the "Last updated" date above and present the new version the next time you open this screen.
            """
        ),
        Section(
            heading: "Contact",
            body: """
            Questions about privacy? Email privacy@chessplus.app.
            """
        )
    ]

    private static let terms: [Section] = [
        Section(
            heading: "Acceptance",
            body: """
            By installing or using Chess+ ("the App") on Apple Vision Pro you agree to these Terms. If you do not agree, do not use the App.
            """
        ),
        Section(
            heading: "License",
            body: """
            We grant you a personal, non-transferable, revocable license to use Chess+ for your own non-commercial chess play, study, and analysis on devices you own or control, subject to these Terms and to Apple's Licensed Application End User License Agreement.
            """
        ),
        Section(
            heading: "Acceptable use",
            body: """
            You agree not to:

            • Reverse-engineer, decompile, or extract source code from the App, except where local law expressly permits it.

            • Use the App to harass other players or to circumvent Lichess's anti-cheat or fair-play policies.

            • Use any automation to cheat in online games, including running engines on positions during rated play.
            """
        ),
        Section(
            heading: "Third-party services",
            body: """
            Online play and analysis rely on Lichess. Your use of those features is also governed by lichess.org's Terms of Service and Privacy Policy. We are not responsible for outages, bans, or changes to Lichess's APIs.
            """
        ),
        Section(
            heading: "Open-source components",
            body: """
            Chess+ ships with the Stockfish engine (GPL-3.0) and integrates with the Lichess API. The corresponding licenses and notices are available from the App's About section.
            """
        ),
        Section(
            heading: "Disclaimer",
            body: """
            The App is provided "as is" without warranties of any kind. Engine evaluations, accuracy scores, and move classifications are heuristics — they may be wrong, especially in complex tactical positions, and should not be treated as authoritative.
            """
        ),
        Section(
            heading: "Limitation of liability",
            body: """
            To the maximum extent permitted by law, Chess+ and its authors are not liable for any indirect, incidental, or consequential damages arising from your use of the App.
            """
        ),
        Section(
            heading: "Termination",
            body: """
            You may stop using Chess+ at any time by deleting it. We may suspend or terminate access if you breach these Terms.
            """
        ),
        Section(
            heading: "Changes",
            body: """
            We may update these Terms. Continued use of the App after an update means you accept the new Terms.
            """
        ),
        Section(
            heading: "Contact",
            body: """
            Questions about these Terms? Email legal@chessplus.app.
            """
        )
    ]
}

struct NotificationsPlaceholderView: View {
    var body: some View {
        LichessGate(
            icon: "bell.fill",
            title: "Notifications",
            signedOutMessage: "Sign in with Lichess to see your notifications.",
            accentColor: .indigo
        ) {
            ComingSoonView(
                icon: "bell.fill",
                title: "Notifications",
                description: "Challenges, game alerts, and messages from Lichess will appear here.",
                accentColor: .indigo
            )
        }
        .navigationTitle("Notifications")
    }
}

// MARK: - Shared UI helpers

private struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ErrorStateCard: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load games")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
