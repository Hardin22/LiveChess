import Foundation
import RealityKit
import TabletopKit
import Spatial
import simd

/// Bridges TabletopKit's abstract game state to RealityKit entities.
///
/// We own one parent `Entity` per piece (`pieceEntities`) plus the
/// programmatic `BoardSurface` group as a child of `rootEntity`. On every
/// frame, `onUpdate` reads each piece's pose from `TableVisualState` and
/// applies it to the matching RealityKit entity. `updateRootPose` keeps
/// the whole scene anchored to the world position TabletopKit picks for
/// the table.
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

    func registerPiece(_ piece: ChessPieceEquipment) {
        let entity = PieceMeshFactory.makeEntity(for: piece.piece)
        entity.name = "Piece_\(piece.piece.color)_\(piece.piece.kind)_\(piece.id)"
        rootEntity.addChild(entity)
        pieceEntities[piece.id] = entity
    }

    // MARK: - TabletopGame.RenderDelegate

    func onUpdate(
        timeInterval: Double,
        snapshot: TableSnapshot,
        visualState: TableVisualState
    ) {
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
