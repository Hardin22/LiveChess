import SwiftUI
import RealityKit
import TabletopKit
import Spatial

/// SwiftUI host for the chess `TabletopGame`.
///
/// Builds the table setup with two seats and 32 pieces in the standard
/// starting position, instantiates the `TabletopGame`, and wires a
/// `ChessRenderer` so RealityKit entities track the abstract game state.
@MainActor
struct ChessSceneView: View {

    var body: some View {
        RealityView { content in
            // Pre-load the 12 USDZ piece templates so the per-piece path can
            // clone them synchronously; falls back to procedural placeholders
            // for any model that isn't bundled.
            await PieceMeshFactory.preload()

            let renderer = ChessRenderer()
            let table = ChessTable(id: EquipmentIdentifier(1))

            var setup = TableSetup(tabletop: table)

            // Seats first — TabletopKit asserts at least one seat exists in the
            // setup before TabletopGame init can succeed.
            let whiteSeat = ChessSeat(id: TableSeatIdentifier(1), side: .white)
            let blackSeat = ChessSeat(id: TableSeatIdentifier(2), side: .black)
            setup.add(seat: whiteSeat)
            setup.add(seat: blackSeat)

            // Pieces in the starting position. Equipment is added to TabletopKit
            // (so future actions/interactions know about them) AND to the
            // renderer (which positions the visual at the correct square).
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
            // Lift the table to a comfortable working height in front of the
            // user — the simulator has no real-world surface to anchor against,
            // so without this the board falls to the floor.
            game.rootPose = Pose3D(
                position: Point3D(
                    x: 0,
                    y: Double(SceneMetrics.defaultTableHeight),
                    z: Double(SceneMetrics.defaultTableDepth)
                ),
                rotation: Rotation3D.identity
            )

            content.add(renderer.rootEntity)

            // Tick the game from the render-loop update event.
            _ = content.subscribe(to: SceneEvents.Update.self) { @MainActor event in
                game.update(deltaTime: event.deltaTime)
            }
        }
    }
}
