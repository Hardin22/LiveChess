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
}
