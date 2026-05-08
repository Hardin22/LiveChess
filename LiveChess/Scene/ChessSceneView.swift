import SwiftUI
import RealityKit
import TabletopKit

/// SwiftUI host for the chess `TabletopGame`.
///
/// Builds the table setup with two seats and 32 pieces in the standard
/// starting position, instantiates the `TabletopGame`, and wires a
/// `ChessRenderer` so RealityKit entities track the abstract game state.
@MainActor
struct ChessSceneView: View {

    var body: some View {
        RealityView { content in
            let renderer = ChessRenderer()
            let table = ChessTable(id: EquipmentIdentifier(1))

            var setup = TableSetup(tabletop: table)

            // Seats first — TabletopKit asserts at least one seat exists in the
            // setup before TabletopGame init can succeed.
            let whiteSeat = ChessSeat(id: TableSeatIdentifier(1), side: .white)
            let blackSeat = ChessSeat(id: TableSeatIdentifier(2), side: .black)
            setup.add(seat: whiteSeat)
            setup.add(seat: blackSeat)

            // Pieces in the starting position.
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
                renderer.registerPiece(equipment)
                nextID += 1
            }

            let game = TabletopGame(tableSetup: setup)
            game.claimSeat(whiteSeat)
            game.addRenderDelegate(renderer)

            content.add(renderer.rootEntity)

            // Tick the game from the render-loop update event.
            _ = content.subscribe(to: SceneEvents.Update.self) { @MainActor event in
                game.update(deltaTime: event.deltaTime)
            }
        }
    }
}
