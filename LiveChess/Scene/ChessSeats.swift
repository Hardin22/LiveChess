import Foundation
import TabletopKit
import Spatial

/// Two seats for the chess match, one for each colour. The seat at `+z`
/// (looking up the board) plays Black; the seat at `-z` plays White.
/// Both seats are claimable; the local player is assigned to one of them
/// based on `MatchSettings.humanColor` (currently both default to White).
struct ChessSeat: TableSeat {

    let id: TableSeatIdentifier
    let initialState: TableSeatState

    init(id: TableSeatIdentifier, side: Side) {
        self.id = id
        // Seat at the edge of the table along the z axis, facing the centre.
        let z: Float = side == .white
            ? -SceneMetrics.boardOuterSide / 2 - 0.10
            : +SceneMetrics.boardOuterSide / 2 + 0.10
        let rotation: Angle2D = side == .white ? .zero : Angle2D(radians: .pi)
        self.initialState = TableSeatState(
            pose: TableVisualState.Pose2D(
                position: TableVisualState.Point2D(x: 0, z: Double(z)),
                rotation: rotation
            )
        )
    }
}
