import SwiftUI
import RealityKit
import TabletopKit

/// SwiftUI host for the chess `TabletopGame`.
///
/// Builds the table setup, instantiates 32 pieces in the standard starting
/// position, and wires a `ChessRenderer` into the game so RealityKit
/// entities track the abstract game state. Drives the game's clock from
/// RealityKit's `SceneEvents.Update` stream.
@MainActor
struct ChessSceneView: View {

    var body: some View {
        RealityView { content in
            let renderer = ChessRenderer()
            let table = ChessTable()

            var setup = TableSetup(tabletop: table)

            var nextID = 1
            for square in Square.all {
                guard let piece = Position.standardStart[square] else { continue }
                let equipment = ChessPieceEquipment(
                    id: EquipmentIdentifier(nextID),
                    piece: piece,
                    square: square,
                    parentID: table.id
                )
                setup.add(equipment: equipment)
                renderer.registerPiece(equipment)
                nextID += 1
            }

            let game = TabletopGame(tableSetup: setup)
            game.addRenderDelegate(renderer)

            content.add(renderer.rootEntity)

            // Tick the game from the render-loop update event.
            _ = content.subscribe(to: SceneEvents.Update.self) { @MainActor event in
                game.update(deltaTime: event.deltaTime)
            }
        }
    }
}
