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
