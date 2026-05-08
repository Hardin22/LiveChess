import Foundation
import TabletopKit
import Spatial

/// `Tabletop` conformance for the chess game's table surface. Defines the
/// shape and serves as the parent of every other `Equipment` (pieces).
struct ChessTable: Tabletop {

    let id: EquipmentIdentifier

    var shape: TabletopShape {
        .rectangular(
            width: SceneMetrics.boardOuterSide,
            height: SceneMetrics.boardOuterSide,
            thickness: SceneMetrics.boardThickness
        )
    }

    init(id: EquipmentIdentifier = EquipmentIdentifier(0)) {
        self.id = id
    }
}
