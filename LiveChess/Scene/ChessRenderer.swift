import Foundation
import RealityKit
import TabletopKit
import Spatial
import simd

/// Bridges TabletopKit's abstract game state to RealityKit entities.
///
/// `rootEntity` is the parent of the programmatic `BoardSurface` plus one
/// child entity per piece (`pieceEntities`). For the static phase, pieces
/// are positioned **directly** in `placePiece(_:on:)` from their `Square`,
/// in `rootEntity`-local coordinates. We deliberately do *not* sync from
/// `TableVisualState` per frame: those poses live in world coordinates and
/// would overwrite our root-local placements with stale (0,0)-ish values
/// (TabletopKit doesn't compute visual poses for equipment that hasn't
/// been interacted with yet).
///
/// `updateRootPose` is also a no-op — `ChessSceneView` controls the scene
/// root's world transform itself (via an `AnchorEntity` for table-plane
/// anchoring, plus a manual drag fallback). Letting TabletopKit reset the
/// root to (0,0,0) every frame dropped the entire board to the floor.
///
/// When piece interactions land in Phase 7, `onUpdate` will start syncing
/// the *moved* equipment specifically — equipment IDs that we know have
/// changed since the previous snapshot.
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

    /// Registers `equipment` and positions its visual at the centre of `square`,
    /// resting on the board surface. All coordinates are in `rootEntity`-local
    /// space; `rootEntity`'s world transform is set by the scene host.
    func placePiece(_ equipment: ChessPieceEquipment, on square: Square) {
        let entity = PieceMeshFactory.makeEntity(for: equipment.piece)
        entity.name = "Piece_\(equipment.piece.color)_\(equipment.piece.kind)_\(equipment.id)"
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
        // No-op: see the file header comment. Will sync moved equipment in Phase 7.
    }

    func updateRootPose(_ pose: Pose3D) {
        // No-op: the scene host owns the root's world transform.
    }
}
