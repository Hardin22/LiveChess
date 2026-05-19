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

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "puzzles_starter",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let infos = try? JSONDecoder().decode([LichessPuzzle.PuzzleInfo].self,
                                                    from: data)
        else { return }
        for info in infos {
            guard let cat = PuzzleCategory.bucket(for: info.themes) else { continue }
            pools[cat, default: []].append(LichessPuzzle(puzzle: info))
        }
    }

    /// De-duplicating append. No-op when the puzzle's id is already
    /// in the category's pool. Used by `PuzzlesViewModel.loadMore` to
    /// stream API-fetched puzzles into the shared pool.
    func append(_ puzzle: LichessPuzzle, to category: PuzzleCategory) {
        var list = pools[category, default: []]
        guard !list.contains(where: { $0.puzzle.id == puzzle.puzzle.id }) else { return }
        list.append(puzzle)
        pools[category] = list
    }

    /// Total and solved tally for a category.
    func progress(in category: PuzzleCategory,
                  progressStore: PuzzleProgressStore) -> (solved: Int, total: Int) {
        let all = pools[category] ?? []
        let solved = all.filter { progressStore.isSolved($0.puzzle.id) }.count
        return (solved, all.count)
    }

    /// Returns the next unsolved puzzle the user should attempt in
    /// `category` — sorted by rating starting from the user's
    /// rating ascending, with below-user-rating puzzles as the tail.
    /// Mirrors `PuzzlesViewModel.displayedPuzzles(in:progress:userRating:limit:)`
    /// so the menu's "next up" and the HUD's "next puzzle" agree.
    func nextUnsolved(in category: PuzzleCategory,
                      progress: PuzzleProgressStore,
                      userRating: Int) -> LichessPuzzle? {
        let unsolved = (pools[category] ?? [])
            .filter { !progress.isSolved($0.puzzle.id) }
        let sorted = unsolved.sorted { a, b in
            let ar = a.puzzle.rating ?? Int.max
            let br = b.puzzle.rating ?? Int.max
            let aAbove = ar >= userRating
            let bAbove = br >= userRating
            if aAbove != bAbove { return aAbove }
            return aAbove ? ar < br : ar > br
        }
        return sorted.first
    }
}
