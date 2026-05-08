import Foundation
import TabletopKit
import Spatial

/// `Equipment` conformance for a chess piece on the board.
///
/// One instance per piece (32 in total at the start of a match). Stateful
/// data lives in `BaseEquipmentState` (parent identifier, table-plane pose,
/// bounding box). The Domain `Piece` value is captured immutably here for
/// rendering and is not part of the TabletopKit-managed mutable state.
struct ChessPieceEquipment: Equipment {

    let id: EquipmentIdentifier
    let piece: Piece
    let initialState: BaseEquipmentState

    init(id: EquipmentIdentifier, piece: Piece, square: Square, parentID: EquipmentIdentifier) {
        self.id = id
        self.piece = piece
        self.initialState = BaseEquipmentState(
            parentID: parentID,
            pose: Self.pose(for: square),
            boundingBox: Self.boundingBox(for: piece.kind)
        )
    }

    // MARK: - Private helpers

    private static func pose(for square: Square) -> TableVisualState.Pose2D {
        let size = SceneMetrics.squareSize
        let half = SceneMetrics.boardPlayableSide / 2
        let x = -half + size * (Float(square.file) + 0.5)
        let z = -half + size * (Float(square.rank) + 0.5)
        return TableVisualState.Pose2D(
            position: TableVisualState.Point2D(x: Double(x), z: Double(z)),
            rotation: Angle2D(radians: 0)
        )
    }

    private static func boundingBox(for kind: PieceKind) -> Rect3D {
        let height = Double(SceneMetrics.pieceHeight(for: kind))
        let diameter = Double(SceneMetrics.pieceBaseDiameter)
        return Rect3D(
            origin: Point3D(x: -diameter / 2, y: 0, z: -diameter / 2),
            size: Size3D(width: diameter, height: height, depth: diameter)
        )
    }
}
