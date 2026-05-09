import RealityKit
import TabletopKit

/// Stamped on every piece's `Entity` so SwiftUI gesture handlers can recover
/// "which piece is this and what square is it on" without a parallel lookup
/// table. `square` is mutated by `ChessRenderer.animateMove(_:)` after each
/// move so the next drag gesture starts from a correct origin.
struct ChessPieceComponent: Component {
    let equipmentID: EquipmentIdentifier
    let color: Side
    let kind: PieceKind
    var square: Square
}
