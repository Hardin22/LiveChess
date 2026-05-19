import Foundation
import Observation

/// Persistent puzzle progress: solved IDs, failed IDs, and the
/// user's local Glicko-2 rating — the same algorithm Lichess uses
/// (see `Glicko2.swift`). Lichess only updates its server-side
/// puzzle rating when you play on lichess.org, so the local rating
/// here mirrors lichess.org behaviour for puzzles you solve INSIDE
/// our app.
///
/// Storage layout (each its own UserDefaults key for easy migration):
///   • `LiveChess.SolvedPuzzles.v1`  → JSON `Set<String>` of solved IDs
///   • `LiveChess.FailedPuzzles.v1`  → JSON `Set<String>` of failed IDs
///   • `LiveChess.PuzzleGlicko.v1`   → JSON `Glicko2.Rating`
///
/// Mirrors `PieceCustomization`'s pattern: pure JSON, decode-failure
/// falls back to defaults so a schema bump can't lock the user out.
@MainActor
@Observable
final class PuzzleProgressStore {

    private static let solvedKey       = "LiveChess.SolvedPuzzles.v1"
    private static let failedKey       = "LiveChess.FailedPuzzles.v1"
    private static let glickoKey       = "LiveChess.PuzzleGlicko.v1"
    private static let dailyDoneAtKey  = "LiveChess.DailyCompletedAt.v1"

    /// Puzzles the user solved correctly (first move right).
    private(set) var solvedIDs: Set<String>
    /// Puzzles the user failed (wrong first move) — Lichess
    /// considers these "attempted, done"; they don't reappear.
    private(set) var failedIDs: Set<String>
    /// Live Glicko-2 rating, updated after each solve/fail.
    private(set) var rating: Glicko2.Rating
    /// Last change in rating (positive on solve, negative on fail).
    /// Drives the "+8" / "−12" indicator next to the rating in the
    /// header. `nil` until the user has played at least one puzzle.
    private(set) var lastRatingDelta: Int?
    /// Wall-clock time the user last completed the daily puzzle
    /// (solve OR fail; one attempt). The daily slot stays locked
    /// until 00:01 local on the day AFTER this — `nextDailyUnlock`.
    private(set) var lastDailyCompletedAt: Date?

    init() {
        self.solvedIDs = Self.restoreSet(forKey: Self.solvedKey)
        self.failedIDs = Self.restoreSet(forKey: Self.failedKey)
        self.rating    = Self.restoreRating() ?? .initial
        self.lastRatingDelta = nil
        self.lastDailyCompletedAt = Self.restoreDate(forKey: Self.dailyDoneAtKey)
    }

    // MARK: - Read

    func isSolved(_ id: String) -> Bool   { solvedIDs.contains(id) }
    func isFailed(_ id: String) -> Bool   { failedIDs.contains(id) }
    /// A puzzle is "attempted" if the user has either solved OR
    /// failed it. Lichess pulls both flavours from the rotation —
    /// our browser does the same.
    func isAttempted(_ id: String) -> Bool {
        solvedIDs.contains(id) || failedIDs.contains(id)
    }

    var puzzleRatingInt: Int { Int(rating.rating.rounded()) }

    // MARK: - Seed from Lichess

    /// One-shot seed of the local Glicko state from the user's
    /// Lichess `puzzle` perf, if the local rating hasn't moved from
    /// the default yet. Called when account data lands. After the
    /// first solve/fail the local rating evolves independently;
    /// re-seeding would clobber that progress.
    func seedFromLichess(rating lichessRating: Int?, rd lichessRD: Int?) {
        // Only seed if we're still on the brand-new default — the
        // user hasn't played any puzzle in-app yet.
        let isInitial = self.rating == .initial
        guard isInitial, let lichessRating else { return }
        self.rating = Glicko2.Rating(
            rating: Double(lichessRating),
            rd: Double(lichessRD ?? 110),
            volatility: 0.06
        )
        persistRating()
    }

    // MARK: - Solve / fail

    func recordSolve(puzzleID: String,
                     puzzleRating: Int?,
                     puzzleRD: Int? = nil) {
        guard !isAttempted(puzzleID) else { return }
        let before = puzzleRatingInt
        if let r = puzzleRating {
            rating = Glicko2.update(
                player: rating,
                opponentRating: Double(r),
                opponentRD: Double(puzzleRD ?? 80),
                score: 1.0
            )
            lastRatingDelta = puzzleRatingInt - before
            persistRating()
        }
        solvedIDs.insert(puzzleID)
        persist(solvedIDs, forKey: Self.solvedKey)
    }

    func recordFail(puzzleID: String,
                    puzzleRating: Int?,
                    puzzleRD: Int? = nil) {
        guard !isAttempted(puzzleID) else { return }
        let before = puzzleRatingInt
        if let r = puzzleRating {
            rating = Glicko2.update(
                player: rating,
                opponentRating: Double(r),
                opponentRD: Double(puzzleRD ?? 80),
                score: 0.0
            )
            lastRatingDelta = puzzleRatingInt - before
            persistRating()
        }
        failedIDs.insert(puzzleID)
        persist(failedIDs, forKey: Self.failedKey)
    }

    /// Legacy entry point — older callers wired only `markSolved(id)`
    /// with no rating context. Still works (no Glicko update fires)
    /// so we don't break anyone, but new code should prefer
    /// `recordSolve(puzzleID:puzzleRating:)`.
    func markSolved(_ id: String) {
        guard !isAttempted(id) else { return }
        solvedIDs.insert(id)
        persist(solvedIDs, forKey: Self.solvedKey)
    }

    /// One-shot per day: marks the daily puzzle as attempted (solve
    /// OR fail). The Puzzles screen renders a "next daily at 00:01"
    /// countdown until `nextDailyUnlock`.
    func markDailyCompleted() {
        let now = Date()
        lastDailyCompletedAt = now
        if let data = try? JSONEncoder().encode(now) {
            UserDefaults.standard.set(data, forKey: Self.dailyDoneAtKey)
        }
    }

    /// Local 00:01 on the day AFTER the user finished the daily.
    /// `nil` when the user hasn't completed one yet (so daily is
    /// unlocked).
    var nextDailyUnlock: Date? {
        guard let last = lastDailyCompletedAt else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let startOfThatDay = calendar.startOfDay(for: last)
        guard let nextDay = calendar.date(byAdding: .day, value: 1,
                                          to: startOfThatDay) else { return nil }
        return calendar.date(byAdding: .minute, value: 1, to: nextDay)
    }

    /// True when the daily slot is still locked. Once `Date()`
    /// crosses `nextDailyUnlock`, the slot opens again.
    var isDailyLocked: Bool {
        guard let unlock = nextDailyUnlock else { return false }
        return Date() < unlock
    }

    func resetAll() {
        solvedIDs = []
        failedIDs = []
        rating = .initial
        lastRatingDelta = nil
        lastDailyCompletedAt = nil
        persist(solvedIDs, forKey: Self.solvedKey)
        persist(failedIDs, forKey: Self.failedKey)
        persistRating()
        UserDefaults.standard.removeObject(forKey: Self.dailyDoneAtKey)
    }

    // MARK: - Persistence

    private static func restoreSet(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    private static func restoreRating() -> Glicko2.Rating? {
        guard let data = UserDefaults.standard.data(forKey: glickoKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Glicko2.Rating.self, from: data)
    }

    private static func restoreDate(forKey key: String) -> Date? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    private func persist(_ value: Set<String>, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistRating() {
        guard let data = try? JSONEncoder().encode(rating) else { return }
        UserDefaults.standard.set(data, forKey: Self.glickoKey)
    }
}
