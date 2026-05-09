import SwiftUI
import RealityKit
import TabletopKit
import Spatial

/// SwiftUI host for the chess `TabletopGame`.
///
/// Builds the table setup with two seats and 32 pieces in the standard
/// starting position, instantiates the `TabletopGame`, wires a
/// `ChessRenderer`, and parents the resulting scene root under a "drag
/// pad" so the user can pinch+drag the board frame to position it on
/// any horizontal surface in their room.
///
/// **Placement model (Phase 6):** the scene root is placed at a default
/// world position (~78 cm above the floor, 55 cm in front of the user)
/// and the user can drag it horizontally by grabbing the wooden frame.
/// We do *not* yet auto-anchor to a detected horizontal plane via
/// `AnchorEntity(.plane(...))`; that's the next step (Phase 7+) once the
/// placement gesture is validated.
@MainActor
struct ChessSceneView: View {

    /// Captured scene-space position of the scene root at the start of a
    /// placement drag. Reset to nil between drags so each new drag re-anchors.
    @State private var dragOriginPosition: SIMD3<Float>?

    var body: some View {
        RealityView { content in
            // Pre-load the 12 USDZ piece templates so the per-piece path can
            // clone them synchronously; falls back to procedural placeholders
            // for any model that isn't bundled.
            await PieceMeshFactory.preload()

            let renderer = ChessRenderer()
            let table = ChessTable(id: EquipmentIdentifier(1))

            var setup = TableSetup(tabletop: table)

            // Seats first — TabletopKit asserts at least one seat exists in
            // the setup before TabletopGame init can succeed.
            let whiteSeat = ChessSeat(id: TableSeatIdentifier(1), side: .white)
            let blackSeat = ChessSeat(id: TableSeatIdentifier(2), side: .black)
            setup.add(seat: whiteSeat)
            setup.add(seat: blackSeat)

            // 32 pieces in the starting position. Equipment is added to
            // TabletopKit (so future actions/interactions know about them)
            // AND to the renderer (which positions the visual at the right
            // square in root-local coordinates).
            var nextID = 100
            for square in Square.all {
                guard let piece = Position.standardStart[square] else { continue }
                let equipment = ChessPieceEquipment(
                    id: EquipmentIdentifier(nextID),
                    piece: piece,
                    square: square,
                    parentID: table.id
                )
                setup.add(equipment: equipment)
                renderer.placePiece(equipment, on: square)
                nextID += 1
            }

            let game = TabletopGame(tableSetup: setup)
            game.claimSeat(whiteSeat)
            game.addRenderDelegate(renderer)

            // Position the scene root manually (TabletopKit's rootPose path
            // is intercepted by ChessRenderer.updateRootPose as a no-op).
            renderer.rootEntity.position = SIMD3<Float>(
                0,
                SceneMetrics.defaultTableHeight,
                SceneMetrics.defaultTableDepth
            )
            content.add(renderer.rootEntity)

            // Tick the game from the render-loop update event.
            _ = content.subscribe(to: SceneEvents.Update.self) { @MainActor event in
                game.update(deltaTime: event.deltaTime)
            }
        }
        .gesture(boardPlacementDrag)
    }

    /// Drag the board frame to reposition the entire scene horizontally.
    /// Y is intentionally clamped so the user can't drop the board into
    /// the floor or push it through the ceiling.
    private var boardPlacementDrag: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard value.entity.name == BoardSurface.frameName,
                      let root = sceneRoot(containing: value.entity) else { return }

                // Convert gesture endpoints from gesture-local into scene
                // (world) space and subtract for a true world-space delta.
                let startScenePoint = value.convert(value.startLocation3D, from: .local, to: .scene)
                let nowScenePoint = value.convert(value.location3D, from: .local, to: .scene)
                let delta = nowScenePoint - startScenePoint

                if dragOriginPosition == nil {
                    dragOriginPosition = root.position
                }
                guard let origin = dragOriginPosition else { return }
                root.position = SIMD3<Float>(
                    origin.x + Float(delta.x),
                    origin.y,                        // keep at table height
                    origin.z + Float(delta.z)
                )
            }
            .onEnded { _ in
                dragOriginPosition = nil
            }
    }

    /// Walk up the scene graph from `entity` until we hit the renderer's root
    /// (named `ChessSceneRoot`). The drag gesture is targeted at the frame,
    /// but it's the whole root we want to translate.
    private func sceneRoot(containing entity: Entity) -> Entity? {
        var node: Entity? = entity
        while let n = node {
            if n.name == "ChessSceneRoot" { return n }
            node = n.parent
        }
        return nil
    }
}
