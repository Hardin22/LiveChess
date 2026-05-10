import SwiftUI
import RealityKit

/// Tiny `RealityView` widget that renders a single chess piece with the
/// material the user is currently composing in `PieceCustomizationView`.
/// Rotates the piece slowly so the highlight rolls across the surface
/// (essential for selling glossy / metallic / pearl looks — a static
/// piece reads as flat regardless of how good the PBR is).
///
/// The preview piece is a king by default — most ornate silhouette,
/// best canvas for material judgement. Side toggles let the user
/// preview both the white and black tints in the same window.
@MainActor
struct PiecePreviewView: View {

    let material: PieceMaterial
    @Binding var previewSide: Side
    @Binding var previewKind: PieceKind

    /// Held in @State so the same Entity instance survives view
    /// re-renders. The `make:` closure captures it as the stage's
    /// spinning child; the `onChange` handlers reach into it directly
    /// to swap the piece without traversing the scene graph.
    @State private var turntable = Entity()

    /// `false` until `PieceMeshFactory.preload()` finishes loading the
    /// 12 piece USDZ templates from the bundle. Until then any call
    /// to `installPiece` would fall through to the procedural
    /// placeholder (cylinder + box), which is what the user was
    /// seeing in the preview. We block the install path on this flag
    /// and re-trigger it once the load completes.
    @State private var assetsReady = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            RealityView { content in
                content.add(makeStage(turntable: turntable))
                if assetsReady { installPiece(in: turntable) }
            } update: { _ in
                // Drive the spin from wall-clock time so it stays smooth
                // regardless of how often SwiftUI re-evaluates body.
                // 12 s per revolution feels like a museum turntable —
                // fast enough to roll the highlight, slow enough not
                // to distract from picking colours.
                let seconds = context.date.timeIntervalSinceReferenceDate
                let phase = seconds.truncatingRemainder(dividingBy: 18.0) / 18.0
                turntable.transform.rotation = simd_quatf(
                    angle: Float(phase) * (2 * .pi),
                    axis: SIMD3<Float>(0, 1, 0)
                )
            }
        }
        .frame(height: 320)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            // Lazily warm the piece-template cache the first time the
            // sheet opens. Same call the immersive scene makes — the
            // USDZ templates are needed here too so the preview shows
            // the real meshes, not the procedural placeholder.
            await PieceMeshFactory.preload()
            assetsReady = true
            installPiece(in: turntable)
        }
        .onChange(of: material) { _, _ in if assetsReady { installPiece(in: turntable) } }
        .onChange(of: previewSide) { _, _ in if assetsReady { installPiece(in: turntable) } }
        .onChange(of: previewKind) { _, _ in if assetsReady { installPiece(in: turntable) } }
    }

    /// Replaces the current preview piece with a freshly-built one,
    /// reflecting the latest material/side/kind selection. Cheap —
    /// we're cloning a single cached USDZ template and applying one
    /// PBR material override.
    private func installPiece(in turntable: Entity) {
        turntable.children
            .filter { $0.name == "PreviewPiece" }
            .forEach { $0.removeFromParent() }

        let override = PieceMaterialFactory.material(for: material, side: previewSide)
        let piece = PieceMeshFactory.makeEntity(
            for: Piece(previewKind, previewSide),
            materialOverride: override
        )
        piece.name = "PreviewPiece"
        piece.position = .zero
        // Chess pieces are ~5 cm tall in-game; 1.8× keeps the king /
        // queen comfortably inside the 320 pt frame so the silhouette
        // doesn't poke out the top.
        piece.scale = SIMD3<Float>(repeating: 1.8)
        turntable.addChild(piece)
    }

    /// The stage holds: pedestal disc, ambient + key lights, and the
    /// turntable child that spins the piece. Lights live on the stage
    /// (not the turntable) so they stay still as the piece rotates,
    /// which is what makes the highlight roll across the surface.
    private func makeStage(turntable: Entity) -> Entity {
        let stage = Entity()
        stage.name = "PreviewStage"
        // Window-2D RealityViews have a shallow viewing volume; pull
        // the stage close to the window plane so the piece lands
        // visibly inside the 320 pt frame instead of vanishing into
        // the far clip.
        stage.position = SIMD3<Float>(0, -0.07, -0.10)

        // Soft daylight fill — RealityView in 2D windows doesn't
        // apply IBL automatically; without an explicit fill the
        // shadow side reads as pitch black. Dimmed (1500 → 800) so
        // the preview looks closer to a calm showroom and farther
        // from a stage spotlight.
        let fill = DirectionalLightComponent(
            color: .init(red: 0.92, green: 0.94, blue: 1.0, alpha: 1.0),
            intensity: 800
        )
        let fillEntity = Entity()
        fillEntity.components.set(fill)
        fillEntity.look(
            at: .zero,
            from: SIMD3<Float>(-0.30, 0.40, 0.20),
            relativeTo: stage
        )
        stage.addChild(fillEntity)

        // Warm key spot from front-right — matches the in-game
        // virtual room key colour temperature so the preview predicts
        // the on-table appearance. Dropped 80K → 35K and the cone
        // widened so the highlight rolls more gently across the
        // surface instead of clipping the glossy / metal presets.
        var key = SpotLightComponent(
            color: .init(red: 1.0, green: 0.92, blue: 0.78, alpha: 1.0),
            intensity: 35_000
        )
        key.attenuationRadius = 1.2
        key.innerAngleInDegrees = 50
        key.outerAngleInDegrees = 110
        let keyEntity = Entity()
        keyEntity.components.set(key)
        keyEntity.look(
            at: SIMD3<Float>(0, 0.075, 0),
            from: SIMD3<Float>(0.20, 0.35, 0.25),
            relativeTo: stage
        )
        stage.addChild(keyEntity)

        // Turntable: the piece rides on this; siblings (lights) stay
        // still so the highlight rolls across the surface as the
        // piece spins.
        turntable.name = "Turntable"
        stage.addChild(turntable)

        return stage
    }
}
