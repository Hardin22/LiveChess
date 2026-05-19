import Foundation
import Observation

/// Persistent record of which puzzles the user has already solved, so
/// the Puzzles screen can hide them and surface the next unsolved one
/// in their category on return.
///
/// Storage: a JSON-encoded `Set<String>` in `UserDefaults` under a
/// versioned key — same shape as `PieceCustomization`. Decode failure
/// falls back to an empty set so a future schema migration can't lock
/// the user out of the screen.
@MainActor
@Observable
final class PuzzleProgressStore {

    private static let storageKey = "LiveChess.SolvedPuzzles.v1"

    /// All puzzle IDs the user has ever solved. Mutating it persists
    /// immediately and triggers SwiftUI re-renders.
    private(set) var solvedIDs: Set<String>

    init() {
        self.solvedIDs = Self.restore() ?? []
    }

    func isSolved(_ id: String) -> Bool {
        solvedIDs.contains(id)
    }

    func markSolved(_ id: String) {
        guard !solvedIDs.contains(id) else { return }
        solvedIDs.insert(id)
        persist(solvedIDs)
    }

    /// Reset — wipes the solved set. Intended for a future "reset
    /// progress" affordance in Settings.
    func resetAll() {
        solvedIDs = []
        persist(solvedIDs)
    }

    // MARK: - Persistence

    private static func restore() -> Set<String>? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Set<String>.self, from: data)
    }

    private func persist(_ value: Set<String>) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
