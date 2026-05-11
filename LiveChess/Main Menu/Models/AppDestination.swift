import Foundation

/// Top-level navigation targets selectable from the sidebar.
///
/// `playOnline / playLocal / playBot` all land on `LobbyView` but with a
/// different mode pre-selected so the user lands in the right card.
enum AppDestination: Hashable {
    case home

    case playOnline   // Lichess Quick Pair / Friend
    case playLocal    // On-device Stockfish (single human)
    case playBot      // On-device Stockfish — same lobby card as `playLocal`

    case puzzles
    case gameReview
    case history
    case profile
    case settings
}
