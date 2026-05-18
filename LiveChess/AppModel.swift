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

    /// Which backdrop the immersive scene uses. `.ar` keeps Vision Pro
    /// passthrough on so the board lands on a real-world table via
    /// ARKit plane detection. The other cases swap passthrough for a
    /// bundled USDZ environment (dwarven hall, balcony, esports stage)
    /// with the board pre-seated on the env's table.
    ///
    /// Switching at runtime requires the immersive scene to rebuild —
    /// the picker flow dismisses + re-opens the immersive space.
    var selectedEnvironment: SceneEnvironment = .ar

    /// Convenience for the immersion-style switch in `LiveChessApp`.
    var virtualEnvironmentEnabled: Bool {
        selectedEnvironment.isVirtual
    }

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

    /// User-controlled piece appearance (preset + per-side colour).
    /// Persisted across launches via `UserDefaults`. Read by the
    /// renderer at scene-build time to override the USDZ-baked
    /// materials.
    let pieceCustomization = PieceCustomization()

    /// The match the immersive scene should render. Set by the lobby
    /// (or the Lichess controller when an online game starts) immediately
    /// before opening the immersive space, then read by `ChessSceneView`
    /// at first appearance to decide whether to wire up the local
    /// `MatchCoordinator` or the remote `LichessMatchSession`. Cleared
    /// when the immersive space dismisses.
    var activeSession: ActiveSession?

    /// Set when the user taps "Find opponent" — drives the matchmaking
    /// HUD that floats over the empty board while we wait for Lichess
    /// to pair us. Cleared when a real game arrives (which transitions
    /// the immersive into `.online` mode) or the user cancels.
    var matchmaking: MatchmakingState?
}

/// Describes an in-flight matchmaking attempt — what the user picked
/// in the lobby. Drives the `MatchmakingHUDView` text/animation.
struct MatchmakingState: Equatable {
    /// Display string for the time control, e.g. "10+0".
    let timeControlLabel: String
    /// Whether the game is rated — surfaced as "Rated" / "Casual".
    let rated: Bool
    /// Username + rating to render on the "You" side of the vs panel.
    let selfUsername: String
    let selfRating: Int?
}

/// Discriminated union over the two flavours of session the scene host
/// can render. The `session` accessor returns the protocol-level value
/// the scene actually uses; the cases stay so HUD code can branch on
/// them for source-specific affordances (resign vs offer-draw vs
/// new-game button text, etc.).
enum ActiveSession {
    case local(MatchCoordinator)
    case online(LichessMatchSession)
    case puzzle(PuzzleSession)
    case review(ReviewSession)

    /// Scene-host accessor — agnostic of which flow we're in.
    var session: any MatchSession {
        switch self {
        case .local(let c):  return c
        case .online(let s): return s
        case .puzzle(let p): return p
        case .review(let r): return r
        }
    }
}
