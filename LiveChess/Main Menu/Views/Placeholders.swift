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
// Real data: `/api/puzzle/daily` + `/api/puzzle/next`. Both public, so
// the screen works for guests too.

@Observable
@MainActor
final class PuzzlesViewModel {
    var dailyPuzzle: LichessPuzzle?
    var recentPuzzles: [LichessPuzzle] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    private let service = LichessService()
    private var hasLoaded = false

    func load(token: String?) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await service.authenticate(token: token)
        isLoading = true
        defer { isLoading = false }

        do {
            async let daily = service.fetchDailyPuzzle()
            async let next = service.fetchNextPuzzle()
            let (d, n) = try await (daily, next)
            dailyPuzzle = d
            recentPuzzles = [n]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(token: String?) async {
        guard !isLoadingMore else { return }
        await service.authenticate(token: token)
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await service.fetchNextPuzzle()
            // Avoid duplicates if the API hands us the same puzzle back.
            if !recentPuzzles.contains(where: { $0.puzzle.id == next.puzzle.id }) {
                recentPuzzles.append(next)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PuzzlesPlaceholderView: View {
    @Environment(AppModel.self) private var appModel
    @State private var viewModel = PuzzlesViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if viewModel.isLoading && viewModel.dailyPuzzle == nil {
                    VStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in PuzzleCardSkeleton() }
                    }
                } else if let error = viewModel.errorMessage,
                          viewModel.dailyPuzzle == nil {
                    PuzzlesErrorState(message: error) {
                        Task { await reload() }
                    }
                } else {
                    if let daily = viewModel.dailyPuzzle {
                        SectionHeader(title: "Daily Puzzle")
                        PuzzleCard(puzzle: daily, isDaily: true)
                    }

                    if !viewModel.recentPuzzles.isEmpty {
                        SectionHeader(title: "More Puzzles")
                        VStack(spacing: 10) {
                            ForEach(viewModel.recentPuzzles, id: \.puzzle.id) { p in
                                PuzzleCard(puzzle: p, isDaily: false)
                            }
                        }
                    }

                    Button {
                        Task { await viewModel.loadMore(token: appModel.lichess.token) }
                    } label: {
                        HStack {
                            if viewModel.isLoadingMore {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(viewModel.isLoadingMore ? "Loading…" : "Load another puzzle")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(viewModel.isLoadingMore)
                    .padding(.top, 8)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
        .navigationTitle("Puzzles")
        .task {
            await viewModel.load(token: appModel.lichess.token)
        }
        .refreshable {
            await reload()
        }
    }

    private func reload() async {
        viewModel = PuzzlesViewModel()
        await viewModel.load(token: appModel.lichess.token)
    }
}

private struct PuzzleCard: View {
    let puzzle: LichessPuzzle
    let isDaily: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Chess.Palette.bronze.gradient.opacity(0.25))
                    .frame(width: 56, height: 56)
                Image(systemName: "puzzlepiece.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isDaily {
                        Text("DAILY")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                    Text("#\(puzzle.puzzle.id)")
                        .font(.callout)
                        .fontWeight(.semibold)
                }

                HStack(spacing: 8) {
                    if let rating = puzzle.puzzle.rating {
                        Label("\(rating)", systemImage: "chart.bar.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let plays = puzzle.puzzle.plays {
                        Label(playsString(plays), systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let moves = puzzle.puzzle.solution?.count {
                        Label("\(moves) moves", systemImage: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !puzzle.puzzle.themes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(puzzle.puzzle.themes.prefix(4), id: \.self) { theme in
                            Text(theme)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()

            Link(destination: URL(string: "https://lichess.org/training/\(puzzle.puzzle.id)")!) {
                Label("Solve", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.purple.opacity(0.25), in: Capsule())
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func playsString(_ plays: Int) -> String {
        if plays >= 1_000_000 { return String(format: "%.1fM", Double(plays) / 1_000_000) }
        if plays >= 1_000 { return String(format: "%.1fk", Double(plays) / 1_000) }
        return "\(plays)"
    }
}

private struct PuzzleCardSkeleton: View {
    @State private var opacity = 0.4
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.12)).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 120, height: 12)
                Capsule().fill(.white.opacity(0.08)).frame(width: 200, height: 10)
                Capsule().fill(.white.opacity(0.08)).frame(width: 160, height: 10)
            }
            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                opacity = 0.9
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
                    Task { await appModel.lichess.signOut() }
                } label: {
                    Label("Sign out of Lichess", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: 280)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .padding(.top, 12)

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
        return row.provisional ? "\(r)?" : "\(r)"
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
    @Environment(\.openWindow) private var openWindow

    enum Section: String, CaseIterable, Identifiable {
        case account, gameplay, boardAndPieces, environment, review, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .account:        return "Account"
            case .gameplay:       return "Gameplay"
            case .boardAndPieces: return "Board & Pieces"
            case .environment:    return "Environment"
            case .review:         return "Game Review"
            case .about:          return "About"
            }
        }
        var systemImage: String {
            switch self {
            case .account:        return "person.crop.circle.fill"
            case .gameplay:       return "flag.checkered"
            case .boardAndPieces: return "checkerboard.rectangle"
            case .environment:    return "mountain.2.fill"
            case .review:         return "magnifyingglass.circle.fill"
            case .about:          return "info.circle.fill"
            }
        }
        var subtitle: String {
            switch self {
            case .account:        return "Lichess sign-in and account info."
            case .gameplay:       return "Default color, Stockfish strength, and thinking time."
            case .boardAndPieces: return "Piece set and board surface for the 3D scene."
            case .environment:    return "Where the board lives when you open an immersive match."
            case .review:         return "How Chess+ classifies your moves after a game."
            case .about:          return "Version, credits, and the platforms we build on."
            }
        }
    }

    @State private var selection: Section = .account

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
        Button { selection = sec } label: {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: sec.systemImage)
                    .foregroundStyle(Chess.Palette.bronze)
                    .frame(width: 22)
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
                          ? AnyShapeStyle(Chess.Palette.cream.opacity(0.18))
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.45)
                                  : .white.opacity(0.08),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
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
            case .review:         reviewPane
            case .about:          aboutPane
            }
        }
        .frame(maxWidth: 720, alignment: .topLeading)
    }

    private func paneHeader(_ sec: Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sec.title)
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(Chess.Palette.accent)
            Text(sec.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
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
                            .font(.title)
                            .foregroundStyle(Chess.Palette.bronze)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appModel.lichess.account?.username ?? "Signed in")
                                .font(.title3.weight(.semibold))
                            Text("Lichess connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider().overlay(Chess.Palette.bronze.opacity(0.25))
                    if let perfs = appModel.lichess.account?.perfs {
                        let popular = ["rapid", "blitz", "bullet", "classical"]
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
                                        VStack(spacing: 2) {
                                            Text("\(rating)")
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(Chess.Palette.bronze)
                                            Text(label)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, Chess.Space.s)
                                        .background(.thinMaterial,
                                                    in: RoundedRectangle(cornerRadius: Chess.Radius.chip))
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
                                .font(.title)
                                .foregroundStyle(.secondary)
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
                    Text("Default color")
                        .font(Chess.Typography.eyebrow())
                        .foregroundStyle(.secondary)
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
                    HStack {
                        Text("Stockfish skill")
                            .font(Chess.Typography.eyebrow())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(appModel.matchSettings.aiSettings.skillLevel) / \(AISettings.maxSkillLevel)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Chess.Palette.bronze)
                    }
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
                    HStack {
                        Text("Thinking time")
                            .font(Chess.Typography.eyebrow())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(String(format: "%.1f", seconds))s per move")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Chess.Palette.bronze)
                    }
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
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                HStack(spacing: Chess.Space.s) {
                    Image(systemName: "paintbrush.fill")
                        .font(.title)
                        .foregroundStyle(Chess.Palette.bronze)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appModel.pieceCustomization.current.preset.displayName)
                            .font(.title3.weight(.semibold))
                        Text("Current piece set")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("Piece materials, board surface, and per-side colours have their own dedicated window so you can preview the 3D set live as you tweak it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    openWindow(id: LiveChessApp.piecesWindowID)
                } label: {
                    Label("Open customizer", systemImage: "rectangle.expand.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.bronze)
                .controlSize(.large)
            }
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
                VStack(spacing: 6) {
                    ForEach(SceneEnvironment.allCases) { env in
                        environmentRow(env, appModel: appModel)
                    }
                }
            }
        }
    }

    private func environmentRow(_ env: SceneEnvironment, appModel: AppModel) -> some View {
        let isSelected = appModel.selectedEnvironment == env
        return Button { appModel.selectedEnvironment = env } label: {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: env.systemImage)
                    .foregroundStyle(Chess.Palette.bronze)
                    .frame(width: 22)
                Text(env.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Chess.Palette.bronze)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, Chess.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Chess.Palette.cream.opacity(0.18))
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.45)
                                  : .white.opacity(0.08),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: Pane — Game Review

    @ViewBuilder
    private var reviewPane: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                settingRow("Eval source",
                           value: "Lichess cloud, with local Stockfish 18 fallback at depth 15",
                           icon: "cpu")
                settingRow("Labelling",
                           value: "chess.com-style buckets (Excellent / Good / Inaccuracy / Mistake / Blunder)",
                           icon: "tag.fill")
                settingRow("Win% formula",
                           value: "chess.com sigmoid: 50 + 50·(2/(1+e^(-0.004·cp)) − 1)",
                           icon: "function")
                settingRow("Mate detection",
                           value: "Catches ~97% of forced mates at depth 15 (vs ~93% at depth 10)",
                           icon: "crown.fill")
                Text("These are baked-in defaults today. A tunable depth + label-style toggle is on the roadmap.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
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
            ChessCard(.standard) {
                VStack(alignment: .leading, spacing: Chess.Space.s) {
                    Text("BUILT ON")
                        .font(Chess.Typography.eyebrow())
                        .foregroundStyle(.secondary)
                    aboutLink("Lichess",
                              subtitle: "Open-source chess platform powering online play.",
                              url: "https://lichess.org",
                              icon: "globe")
                    aboutLink("chess.com",
                              subtitle: "Reference benchmark for move classification.",
                              url: "https://www.chess.com",
                              icon: "checkerboard.rectangle")
                    aboutLink("Stockfish",
                              subtitle: "The open-source engine that powers analysis.",
                              url: "https://stockfishchess.org",
                              icon: "cpu")
                }
            }
        }
    }

    // MARK: Helpers

    private func settingRow(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: Chess.Space.s) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Chess.Palette.bronze.opacity(0.85))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func aboutLink(_ title: String, subtitle: String, url: String, icon: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(Chess.Palette.bronze.opacity(0.85))
                    .frame(width: 22)
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
