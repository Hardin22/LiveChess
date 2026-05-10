//
//  LiveChessApp.swift
//  LiveChess
//
//  Created by Francesco Albano on 08/05/26.
//

import SwiftUI

@main
struct LiveChessApp: App {

    @State private var appModel = AppModel()
    /// Source of truth for the immersive's style. Mirrored to
    /// `appModel.virtualEnvironmentEnabled` so the HUD's toggle
    /// button can drive it (see `.onChange` below). `ImmersionStyle`
    /// without `any`/`some` is the existential the modifier expects
    /// for multi-style selection.
    @State private var immersionStyle: ImmersionStyle = MixedImmersionStyle()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
                .onChange(of: appModel.virtualEnvironmentEnabled) { _, isVirtual in
                    immersionStyle = isVirtual
                        ? FullImmersionStyle()
                        : MixedImmersionStyle()
                }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }
}
