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
                    .fill(Color.purple.gradient.opacity(0.25))
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
        games.filter { $0.accuracy(for: username) != nil }
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

    private static let displayedPerfs: [(key: String, label: String)] = [
        ("bullet", "Bullet"),
        ("blitz", "Blitz"),
        ("rapid", "Rapid"),
        ("classical", "Classical")
    ]

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
                    ForEach(Self.displayedPerfs, id: \.key) { entry in
                        ratingChip(label: entry.label, key: entry.key)
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
    private func ratingChip(label: String, key: String) -> some View {
        let rating = account.rating(forPerfKey: key)
        let games = account.perfs?[key]?.games
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rating.map { "\($0)" } ?? "—")
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
            Text(games.map { "\($0) games" } ?? " ")
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
}

// MARK: - Settings & Notifications (still placeholders)

struct SettingsPlaceholderView: View {
    var body: some View {
        ComingSoonView(
            icon: "gearshape.fill",
            title: "Settings",
            description: "Configure your board theme, piece style, language, and Lichess account.",
            accentColor: .gray
        )
        .navigationTitle("Settings")
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
