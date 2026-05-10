//
//  AppModel.swift
//  LiveChess
//
//  Created by Francesco Albano on 08/05/26.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// Whether the immersive scene replaces real-world passthrough with
    /// the bundled virtual environment (a small chess room with table +
    /// chairs). Off by default so first-time users see the chessboard
    /// floating in their actual room (the AR experience). Toggling at
    /// runtime requires the immersive scene to rebuild — the toggle
    /// flow dismisses + re-opens the immersive space.
    var virtualEnvironmentEnabled: Bool = false

    /// Set briefly by the env-toggle flow so `ChessSceneView.onDisappear`
    /// keeps the active session alive across the dismiss + re-open.
    /// Cleared by the next `onAppear` so subsequent ordinary closes
    /// behave as before (clearing the session).
    var pendingReopen: Bool = false

    /// Lobby choices the user makes before opening the board.
    var matchSettings = MatchSettings()

    /// Long-lived Lichess auth + account state. Bootstrapped on first
    /// appearance of the lobby (`.task { await appModel.lichess.bootstrap() }`).
    /// Carries the bearer token for the rest of the app's Lichess flows.
    let lichess = LichessSession()

    /// The match the immersive scene should render. Set by the lobby
    /// (or the Lichess controller when an online game starts) immediately
    /// before opening the immersive space, then read by `ChessSceneView`
    /// at first appearance to decide whether to wire up the local
    /// `MatchCoordinator` or the remote `LichessMatchSession`. Cleared
    /// when the immersive space dismisses.
    var activeSession: ActiveSession?
}

/// Discriminated union over the two flavours of session the scene host
/// can render. The `session` accessor returns the protocol-level value
/// the scene actually uses; the cases stay so HUD code can branch on
/// them for source-specific affordances (resign vs offer-draw vs
/// new-game button text, etc.).
enum ActiveSession {
    case local(MatchCoordinator)
    case online(LichessMatchSession)

    /// Scene-host accessor — agnostic of which flow we're in.
    var session: any MatchSession {
        switch self {
        case .local(let c): return c
        case .online(let s): return s
        }
    }
}
