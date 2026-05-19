// ViewModels/HomeViewModel.swift
// View-model for the Home screen. Owns the lists of recent games + the
// daily puzzle that the Home tiles render. The signed-in user itself is
// NOT fetched here — `LichessSession` (held on `AppModel`) is the single
// source of truth for that, so the home screen reads its account
// straight off the session via `attach(session:)`.

import Foundation
import Observation
import SwiftUI   // `withAnimation` lives here

@Observable
@MainActor
final class HomeViewModel {

    // MARK: - Navigation State
    /// Which sidebar item is currently selected. Optional because
    /// visionOS's `List(selection:)` requires `Binding<SelectionValue?>`.
    var selectedDestination: AppDestination? = .home

    /// Whether the "Play" submenu is expanded in the sidebar.
    var isPlayExpanded: Bool = true

    // MARK: - Lichess Session
    /// The shared session. Set by `ContentView` once on appear so the
    /// home screen can read the signed-in account + fetch the user's
    /// games against the same bearer token the rest of the app uses.
    private(set) var session: LichessSession?

    // MARK: - Data State
    /// Games fetched from `/api/games/user/{username}`. Empty while
    /// signed out — Lichess won't return another user's games without
    /// a token anyway, and the home tiles render an empty state.
    var games: [LichessGame] = []
    /// `/api/puzzle/daily` — works without auth, so we show it even
    /// when the user is a guest.
    var puzzle: LichessPuzzle?

    // MARK: - UI State
    var isLoadingGames: Bool = false
    var isLoadingPuzzle: Bool = false
    var errorMessage: String?

    /// Search bar text — filters the recent-games list client-side.
    var searchText: String = ""

    // MARK: - Service
    private let service = LichessService()

    // MARK: - Computed accessors

    /// Whether the user is currently signed in to Lichess.
    var isSignedIn: Bool {
        session?.isSignedIn ?? false
    }

    /// The signed-in account snapshot, or `nil` while signed out /
    /// during bootstrap.
    var account: LichessAccount? {
        session?.account
    }

    /// Display name shown in the welcome line + sidebar footer. Falls
    /// back to "Guest" for signed-out users.
    var displayUsername: String {
        account?.username ?? "Guest"
    }

    /// Rating shown in the stats chip. `0` is treated as "no rating
    /// yet" by the chip itself (renders as "—").
    var displayRating: Int {
        account?.rating(forPerfKey: "rapid") ?? 0
    }

    /// Number of rapid games played — used to drive the "games" chip.
    var displayGamesPlayed: Int? {
        account?.perfs?["rapid"]?.games
    }

    /// Rating-strip rows shown on the home header. Empty when signed
    /// out so the chips disappear cleanly instead of rendering a row
    /// of "—". Order mirrors `LichessAccount.displayedPerfKeys`.
    var displayedRatings: [LichessAccount.RatingRow] {
        account?.displayedRatingRows ?? []
    }

    /// Games filtered by the search bar against opponent name + opening.
    var filteredGames: [LichessGame] {
        if searchText.isEmpty { return games }
        let username = account?.username ?? ""
        return games.filter { game in
            game.opponent(for: username).localizedCaseInsensitiveContains(searchText)
                || (game.opening?.name?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// First (most-recent) game in the list — drives the "Game Review"
    /// feature card.
    var latestGame: LichessGame? { games.first }

    // MARK: - Wiring

    /// Inject the shared Lichess session. Called once from `ContentView`
    /// on appear. Idempotent — re-attaching the same session is a no-op.
    func attach(session: LichessSession) {
        guard self.session !== session else { return }
        self.session = session
    }

    // MARK: - Loading

    /// Called on first appearance and from the pull-to-refresh gesture.
    /// Pulls the latest token off the session, hands it to the REST
    /// client, then fetches games + the daily puzzle concurrently.
    func loadInitialData() async {
        await service.authenticate(token: session?.token)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadGames() }
            group.addTask { await self.loadPuzzle() }
        }
    }

    /// Refresh on user action.
    func refreshAll() async {
        await loadInitialData()
    }

    private func loadGames() async {
        // Without a signed-in account there's no username to fetch
        // games for — drop the list and skip the request.
        guard let username = account?.username else {
            games = []
            return
        }
        isLoadingGames = true
        defer { isLoadingGames = false }
        do {
            games = try await service.fetchRecentGames(
                username: username,
                count: 15,
                withAnalysis: true,
                withOpening: true
            )
        } catch {
            errorMessage = "Could not load games: \(error.localizedDescription)"
        }
    }

    private func loadPuzzle() async {
        isLoadingPuzzle = true
        defer { isLoadingPuzzle = false }
        do {
            puzzle = try await service.fetchDailyPuzzle()
        } catch {
            // Non-fatal: puzzle failing shouldn't break the whole screen.
            print("⚠️ Puzzle load failed: \(error)")
        }
    }

    // MARK: - Navigation

    func navigate(to destination: AppDestination) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedDestination = destination
        }
    }
}
