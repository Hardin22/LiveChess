import Foundation
import RealityKit
import TabletopKit
import Spatial
import simd

/// Bridges TabletopKit's abstract game state to RealityKit entities.
///
/// `rootEntity` is the parent of the programmatic `BoardSurface` plus one
/// child entity per piece (`pieceEntities`). For Phase 6 we position pieces
/// **directly** in `placePiece(_:on:)` from the `Square`, rather than reading
/// `TableVisualState.pose(matching:)`. TabletopKit doesn't populate visual
/// poses for equipment that hasn't been interacted with yet, so leaning on
/// it for static layout left every piece stacked at the table origin. The
/// per-frame `onUpdate` keeps the visual in sync only for equipment that
/// TabletopKit *does* report a pose for (post-interaction).
@MainActor
final class ChessRenderer: TabletopGame.RenderDelegate {

    let rootEntity: Entity
    private let boardEntity: Entity
    private var pieceEntities: [EquipmentIdentifier: Entity] = [:]

    init() {
        self.rootEntity = Entity()
        self.rootEntity.name = "ChessSceneRoot"
        self.boardEntity = BoardSurface.makeEntity()
        self.rootEntity.addChild(boardEntity)
    }

    /// Registers `equipment` with the renderer and positions its visual
    /// directly above the centre of `square` on the board.
    func placePiece(_ equipment: ChessPieceEquipment, on square: Square) {
        let entity = PieceMeshFactory.makeEntity(for: equipment.piece)
        entity.name = "Piece_\(equipment.piece.color)_\(equipment.piece.kind)_\(equipment.id)"
        // Sit on the board surface (square top is just above frame top).
        var pos = BoardSurface.position(for: square)
        pos.y = SceneMetrics.squareThickness
        entity.position = pos
        rootEntity.addChild(entity)
        pieceEntities[equipment.id] = entity
    }

    // MARK: - TabletopGame.RenderDelegate

    func onUpdate(
        timeInterval: Double,
        snapshot: TableSnapshot,
        visualState: TableVisualState
    ) {
        // Only sync entities for which TabletopKit reports a pose. This kicks
        // in once a piece is actually moved through a TabletopAction, leaving
        // initial-state placements (set in placePiece) untouched.
        for (id, entity) in pieceEntities {
            guard let pose = visualState.pose(matching: id) else { continue }
            entity.position = SIMD3<Float>(
                Float(pose.position.x),
                Float(pose.position.y),
                Float(pose.position.z)
            )
            let q = pose.rotation.quaternion
            entity.orientation = simd_quatf(
                ix: Float(q.imag.x),
                iy: Float(q.imag.y),
                iz: Float(q.imag.z),
                r: Float(q.real)
            )
        }
    }

    func updateRootPose(_ pose: Pose3D) {
        rootEntity.position = SIMD3<Float>(
            Float(pose.position.x),
            Float(pose.position.y),
            Float(pose.position.z)
        )
        let q = pose.rotation.quaternion
        rootEntity.orientation = simd_quatf(
            ix: Float(q.imag.x),
            iy: Float(q.imag.y),
            iz: Float(q.imag.z),
            r: Float(q.real)
        )
    }
}
