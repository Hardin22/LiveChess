//
//  ContentView.swift
//  LiveChess
//
//  Created by Francesco Albano on 08/05/26.
//

import SwiftUI

/// The window root. Currently just hosts `LobbyView`; will gain post-game
/// summary / return-to-lobby logic when the game loop is wired up.
struct ContentView: View {
    var body: some View {
        LobbyView()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
