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
        // Explicit `id` so we can dismiss / reopen the menu window
        // when the immersive scene opens / closes (otherwise the
        // floating panel stays in front of the chessboard).
        WindowGroup(id: Self.menuWindowID) {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSceneHost(appModel: appModel)
                .onChange(of: appModel.virtualEnvironmentEnabled) { _, isVirtual in
                    immersionStyle = isVirtual
                        ? FullImmersionStyle()
                        : MixedImmersionStyle()
                }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }

    /// Window-group id for the Main Menu panel.
    static let menuWindowID = "MainMenu"
}

/// Wrapper around `ImmersiveView` that owns the window-management
/// side-effects. Lives inside the immersive scene so it has access to
/// `dismissWindow` / `openWindow` (which are `@Environment` values and
/// therefore only available inside a `View`, not directly in `App`).
///
/// On open: stamps state + dismisses the floating Main Menu window so
/// the chessboard isn't competing with a UI panel.
/// On close: stamps state + re-opens the Main Menu window so the user
/// lands back on the home screen.
///
/// `pendingReopen` (set by the virtual-env toggle flow) short-circuits
/// the dismiss/reopen cycle — that flow needs the menu window kept
/// alive across the immersive dismiss + re-open.
private struct ImmersiveSceneHost: View {

    let appModel: AppModel

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ImmersiveView()
            .environment(appModel)
            .onAppear {
                appModel.immersiveSpaceState = .open
                if !appModel.pendingReopen {
                    dismissWindow(id: LiveChessApp.menuWindowID)
                }
            }
            .onDisappear {
                appModel.immersiveSpaceState = .closed
                if !appModel.pendingReopen {
                    openWindow(id: LiveChessApp.menuWindowID)
                }
            }
    }
}
