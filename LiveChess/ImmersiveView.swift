//
//  ImmersiveView.swift
//  LiveChess
//
//  Created by Francesco Albano on 08/05/26.
//

import SwiftUI
import RealityKit

/// Hosts the chess scene inside the mixed-reality immersive space.
///
/// Currently a thin wrapper around `ChessSceneView`; future iterations will
/// add a HUD attachment here without touching the scene content itself.
struct ImmersiveView: View {

    var body: some View {
        ChessSceneView()
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
