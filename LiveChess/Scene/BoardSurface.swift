import Foundation
import RealityKit

/// Builds the visible 8×8 chessboard surface as a single RealityKit entity
/// hierarchy. Sits flat in the X-Z plane with the centre at the world
/// origin of its parent. The board is purely visual: piece positioning
/// is driven from the Domain `Square` via `position(for:)`.
@MainActor
enum BoardSurface {

    /// Builds the board entity. The returned root has the frame as a child
    /// at `frameName`, which is the entity scene-hosts use as a drag/hit
    /// target for placement gestures.
    static let frameName = "BoardFrame"

    static func makeEntity() -> Entity {
        let root = Entity()
        root.name = "ChessBoard"

        let frame = makeFrame()
        root.addChild(frame)

        let squares = makeSquares()
        root.addChild(squares)

        return root
    }

    // MARK: - Components

    private static func makeFrame() -> Entity {
        let outer = SceneMetrics.boardOuterSide
        let thickness = SceneMetrics.boardThickness
        let mesh = MeshResource.generateBox(
            size: [outer, thickness, outer],
            cornerRadius: 0.002
        )
        let entity = ModelEntity(mesh: mesh, materials: [ChessMaterials.boardFrame])
        // Sink the frame so its top sits at y = 0; squares sit just above.
        entity.position = [0, -thickness / 2, 0]
        entity.name = frameName
        // Make the frame draggable: required so SwiftUI's DragGesture(targetedTo:)
        // can hit-test the entity. The sibling square boxes are intentionally
        // *not* input targets — only the frame catches placement drags, so a
        // drag on a square or piece can later be routed to game interactions.
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        entity.generateCollisionShapes(recursive: false)
        return entity
    }

    private static func makeSquares() -> Entity {
        let group = Entity()
        group.name = "BoardSquares"

        let size = SceneMetrics.squareSize
        let half = SceneMetrics.boardPlayableSide / 2

        for rank in 0..<8 {
            for file in 0..<8 {
                let isLight = (file + rank).isMultiple(of: 2)
                let squareEntity = ModelEntity(
                    mesh: .generateBox(
                        size: [size, SceneMetrics.squareThickness, size],
                        cornerRadius: 0.0005
                    ),
                    materials: [ChessMaterials.square(forIsLight: isLight)]
                )
                let x = -half + size * (Float(file) + 0.5)
                let z = -half + size * (Float(rank) + 0.5)
                // Squares sit slightly above the frame top (y > 0) so seams stay clean.
                squareEntity.position = [x, SceneMetrics.squareThickness / 2 - 0.0001, z]
                squareEntity.name = "Square_\(file)_\(rank)"
                group.addChild(squareEntity)
            }
        }
        return group
    }

    // MARK: - World-coordinates helpers

    /// Position (relative to the board root) of the centre of a `Square`,
    /// at the surface plane (`y = 0`).
    static func position(for square: Square) -> SIMD3<Float> {
        let size = SceneMetrics.squareSize
        let half = SceneMetrics.boardPlayableSide / 2
        let x = -half + size * (Float(square.file) + 0.5)
        let z = -half + size * (Float(square.rank) + 0.5)
        return [x, 0, z]
    }
}
