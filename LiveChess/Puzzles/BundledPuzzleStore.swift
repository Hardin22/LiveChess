import Foundation
import Observation

/// App-wide pool of bundled + API-fetched puzzles, keyed by category.
/// Lives on `AppModel` so both the Puzzles browser and the immersive
/// HUD (`PuzzleHUDView`) can read from it — the HUD needs it to power
/// the "Next puzzle" button shown after a successful solve.
///
/// The bundled starter pack (`Resources/puzzles_starter.json`) is
/// decoded once on first access. `append(_:to:)` is how the menu's
/// "Load more" pushes API-fetched puzzles into the same pool so they
/// flow through to the in-immersive Next button as well.
@MainActor
@Observable
final class BundledPuzzleStore {

    private(set) var pools: [PuzzleCategory: [LichessPuzzle]] = [:]
    private var loaded = false

    /// Shared service used to top up the pool from Lichess when the
    /// bundled set runs out. Held here (instead of in each call site)
    /// so the auth-token reauthentication only happens once.
    private let service = LichessService()
    private var lastAuthedToken: String?

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "puzzles_starter",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let infos = try? JSONDecoder().decode([LichessPuzzle.PuzzleInfo].self,
                                                    from: data)
        else { return }

        // Balanced bucketing: assign each puzzle to the LEAST-FILLED
        // category among its theme matches. Naïve priority-order
        // (`PuzzleCategory.bucket`) gives every puzzle to mateIn1 /
        // mateIn2 / mateIn3 / endgame / middlegame / opening before
        // the tactic rows ever see one — because virtually every
        // bundled puzzle carries one of those themes alongside its
        // tactic tag. Mirrors the same strategy the Python sampling
        // script (`scripts/generate_starter_puzzles_from_db.py`) uses.
        var buckets: [PuzzleCategory: [LichessPuzzle]] = [:]
        for info in infos {
            // Skip puzzles without a usable FEN — they'd silently
            // fail in PuzzleSession.init and look like a broken
            // 'Solve next' button to the user.
            guard let fen = info.fen, !fen.isEmpty else { continue }
            let themes = Set(info.themes)
            var leastFilled: PuzzleCategory? = nil
            var leastCount = Int.max
            for cat in PuzzleCategory.allCases {
                guard !themes.isDisjoint(with: cat.themeKeys) else { continue }
                let count = buckets[cat]?.count ?? 0
                if count < leastCount {
                    leastCount = count
                    leastFilled = cat
                }
            }
            guard let target = leastFilled else { continue }
            _ = fen   // silence unused-let warning
            buckets[target, default: []].append(LichessPuzzle(puzzle: info))
        }
        pools = buckets
    }

    /// De-duplicating append. No-op when the puzzle's id is already
    /// in the category's pool. Also rejects puzzles without a FEN —
    /// `/api/puzzle/next` sometimes returns puzzles positioned via
    /// game PGN + `initialPly` instead of a standalone FEN, and
    /// `PuzzleSession.init` can only consume the FEN form, so storing
    /// FEN-less puzzles would just produce silent launch failures.
    func append(_ puzzle: LichessPuzzle, to category: PuzzleCategory) {
        guard let fen = puzzle.puzzle.fen, !fen.isEmpty else { return }
        var list = pools[category, default: []]
        guard !list.contains(where: { $0.puzzle.id == puzzle.puzzle.id }) else { return }
        list.append(puzzle)
        pools[category] = list
    }

    /// Total and "attempted" (solved OR failed) tally. Lichess
    /// considers a failed puzzle as done — wrong first move and
    /// it leaves the rotation. We mirror that here.
    func progress(in category: PuzzleCategory,
                  progressStore: PuzzleProgressStore) -> (solved: Int, total: Int) {
        let all = pools[category] ?? []
        let solved = all.filter { progressStore.isAttempted($0.puzzle.id) }.count
        return (solved, all.count)
    }

    /// Returns the next un-attempted puzzle the user should face in
    /// `category` — solved AND failed puzzles are skipped (matches
    /// lichess.org behaviour: one shot per puzzle, then it's gone).
    /// Sorted by rating ascending starting from `userRating`.
    func nextUnsolved(in category: PuzzleCategory,
                      progress: PuzzleProgressStore,
                      userRating: Int) -> LichessPuzzle? {
        let unattempted = (pools[category] ?? [])
            .filter { !progress.isAttempted($0.puzzle.id) }
        let sorted = unattempted.sorted { a, b in
            let ar = a.puzzle.rating ?? Int.max
            let br = b.puzzle.rating ?? Int.max
            let aAbove = ar >= userRating
            let bAbove = br >= userRating
            if aAbove != bAbove { return aAbove }
            return aAbove ? ar < br : ar > br
        }
        return sorted.first
    }

    /// Always returns a puzzle the user hasn't attempted yet —
    /// either by reading from the local bundle, or, when the bundle
    /// for that category is exhausted, by fetching a fresh one from
    /// Lichess (`/api/puzzle/next?angle=<theme>`). The fetched
    /// puzzle is added to the pool so future calls don't re-hit
    /// the API for the same id.
    ///
    /// Throws if Lichess refuses (rate limit, network failure) AND
    /// the bundle was already empty; caller can surface the error.
    /// Skips API duplicates of already-attempted puzzles by retrying
    /// up to `maxAPIAttempts` times.
    func ensureNextUnsolved(in category: PuzzleCategory,
                            progress: PuzzleProgressStore,
                            userRating: Int,
                            token: String?,
                            maxAPIAttempts: Int = 5) async throws -> LichessPuzzle {
        if let local = nextUnsolved(in: category,
                                     progress: progress,
                                     userRating: userRating) {
            return local
        }
        // Local pool exhausted — keep asking Lichess until we get
        // an un-attempted one (or hit the retry cap).
        if lastAuthedToken != token {
            await service.authenticate(token: token)
            lastAuthedToken = token
        }
        for _ in 0..<maxAPIAttempts {
            let fresh = try await service.fetchNextPuzzle(angle: category.rawValue)
            append(fresh, to: category)
            if !progress.isAttempted(fresh.puzzle.id),
               (fresh.puzzle.fen?.isEmpty == false) {
                return fresh
            }
        }
        // Exhausted retries (unlikely; Lichess's pool is huge).
        // Throw a generic error so the UI shows an inline retry.
        throw LichessAPIError.invalidResponse
    }
}
