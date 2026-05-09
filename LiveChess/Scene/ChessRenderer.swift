import Foundation
import RealityKit
import TabletopKit
import Spatial
import simd

/// Bridges TabletopKit's abstract game state to RealityKit entities, and
/// owns the per-piece animation routing.
///
/// Pieces are positioned directly via `placePiece(_:on:)` in root-local
/// coordinates. Once the coordinator applies a move, `animateMove(_:)`
/// glides the right piece to its new square and disposes of any captured
/// occupant. `snapBack(_:)` handles the cancel/illegal path during a drag.
@MainActor
final class ChessRenderer: TabletopGame.RenderDelegate {

    /// Duration of the glide between two squares.
    static let moveAnimationDuration: TimeInterval = 0.35
    /// How far above the board surface a held/dragging piece floats.
    static let liftHeight: Float = 0.025

    let rootEntity: Entity
    private let boardEntity: Entity
    /// Lookup by Equipment id (TabletopKit tag for the piece).
    private(set) var pieceEntities: [EquipmentIdentifier: Entity] = [:]
    /// Lookup by current square. Updated on every applied move.
    private(set) var pieceBySquare: [Square: Entity] = [:]
    /// Currently visible legal-destination markers, keyed by their square.
    private var legalMarkers: [Square: ModelEntity] = [:]
    /// Square the dragged piece is currently hovering over (subset of
    /// `legalMarkers`). `nil` when the piece is over a non-legal square.
    private var activeMarkerSquare: Square?

    init() {
        self.rootEntity = Entity()
        self.rootEntity.name = "ChessSceneRoot"
        self.boardEntity = BoardSurface.makeEntity()
        self.rootEntity.addChild(boardEntity)
    }

    // MARK: - Setup

    /// Creates the visual entity for `equipment`, parents it under the scene
    /// root, and stamps the wrapper with the `ChessPieceComponent` + the
    /// `InputTargetComponent` + `CollisionComponent` triple that SwiftUI
    /// gestures need.
    ///
    /// We put a *manual* box collision on the wrapper rather than calling
    /// `generateCollisionShapes(recursive: true)`. That call produces shapes
    /// only on descendant `ModelEntity`s (the loaded USDZ mesh), which then
    /// don't carry `InputTargetComponent` — leaving the entity tree with no
    /// node that has both components, so the gesture system never sees a
    /// valid hit. Putting both on the wrapper side-steps the issue and lets
    /// the gesture's `value.entity` resolve directly to the wrapper, where
    /// `ChessPieceComponent` lives.
    func placePiece(_ equipment: ChessPieceEquipment, on square: Square) {
        let entity = PieceMeshFactory.makeEntity(for: equipment.piece)
        entity.name = "Piece_\(equipment.piece.color)_\(equipment.piece.kind)_\(equipment.id)"
        entity.position = surfacePosition(for: square)

        let height = SceneMetrics.pieceHeight(for: equipment.piece.kind)
        let diameter = SceneMetrics.pieceBaseDiameter
        let collisionShape = ShapeResource
            .generateBox(size: [diameter, height, diameter])
            .offsetBy(translation: [0, height / 2, 0])
        entity.components.set(CollisionComponent(shapes: [collisionShape]))
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        entity.components.set(ChessPieceComponent(
            equipmentID: equipment.id,
            color: equipment.piece.color,
            kind: equipment.piece.kind,
            square: square
        ))

        rootEntity.addChild(entity)
        pieceEntities[equipment.id] = entity
        pieceBySquare[square] = entity
    }

    // MARK: - Move animation

    /// Animates the piece on `move.from` to `move.to`. Removes any captured
    /// piece on the destination first; updates the per-square / per-id maps
    /// and the entity's `ChessPieceComponent.square` so the next drag starts
    /// from the correct origin.
    ///
    /// Castling: when `move.isCastle == true`, also slides the matching rook
    /// (h-file → f-file for kingside, a-file → d-file for queenside). The
    /// `Move` we get only describes the king's path — the rook's twin move
    /// is implied by the rules, so we pattern-match and apply it here too.
    func animateMove(_ move: Move) {
        guard let entity = pieceBySquare[move.from] else { return }

        // Capture: remove existing occupant of destination.
        if let captured = pieceBySquare[move.to], captured !== entity {
            captured.removeFromParent()
            if let capturedComp = captured.components[ChessPieceComponent.self] {
                pieceEntities.removeValue(forKey: capturedComp.equipmentID)
            }
            pieceBySquare.removeValue(forKey: move.to)
        }

        glide(entity, to: move.to)

        // Castle: also slide the matching rook.
        if move.isCastle {
            slideCastlingRook(kingFrom: move.from, kingTo: move.to)
        }
    }

    /// Slides `entity` from its current square to `square`, updating
    /// indexes and the piece's `ChessPieceComponent.square` along the way.
    private func glide(_ entity: Entity, to square: Square) {
        if let oldSquare = entity.components[ChessPieceComponent.self]?.square {
            pieceBySquare.removeValue(forKey: oldSquare)
        }
        pieceBySquare[square] = entity

        if var comp = entity.components[ChessPieceComponent.self] {
            comp.square = square
            entity.components.set(comp)
        }

        var target = entity.transform
        target.translation = surfacePosition(for: square)
        entity.move(
            to: target,
            relativeTo: rootEntity,
            duration: Self.moveAnimationDuration,
            timingFunction: .easeOut
        )
    }

    /// Given the king's `from`/`to`, infers and animates the rook half of
    /// a castling move. Kingside if the king's destination file is greater
    /// than its origin (e1→g1 / e8→g8), otherwise queenside.
    private func slideCastlingRook(kingFrom: Square, kingTo: Square) {
        let isKingside = kingTo.file > kingFrom.file
        let rank = kingFrom.rank
        let rookFromFile = isKingside ? 7 : 0
        let rookToFile = isKingside ? 5 : 3
        guard let rookFrom = Square(file: rookFromFile, rank: rank),
              let rookTo = Square(file: rookToFile, rank: rank),
              let rook = pieceBySquare[rookFrom]
        else { return }
        glide(rook, to: rookTo)
    }

    /// Returns the held piece to the centre of its current square. Used when a
    /// drag ends on an illegal target, or when the drag is cancelled.
    func snapBack(_ entity: Entity) {
        guard let comp = entity.components[ChessPieceComponent.self] else { return }
        var target = entity.transform
        target.translation = surfacePosition(for: comp.square)
        entity.move(
            to: target,
            relativeTo: rootEntity,
            duration: 0.2,
            timingFunction: .easeOut
        )
    }

    /// Lifts the piece slightly off the board, keeping its X/Z. Used when a
    /// drag begins so the user has a tactile cue.
    func lift(_ entity: Entity) {
        var target = entity.transform
        target.translation.y = SceneMetrics.squareThickness + Self.liftHeight
        entity.move(
            to: target,
            relativeTo: rootEntity,
            duration: 0.12,
            timingFunction: .easeOut
        )
    }

    // MARK: - Legal-move highlights

    /// Spawns a faint marker on each `square` to show where the dragged
    /// piece can land. Markers fade-and-scale-in over 150 ms.
    func showLegalMoveMarkers(_ squares: [Square]) {
        clearLegalMoveMarkers()
        for square in squares {
            let marker = makeMarker(for: square, active: false)
            legalMarkers[square] = marker
            rootEntity.addChild(marker)

            // Scale-in animation so the markers don't pop into existence.
            marker.transform.scale = SIMD3<Float>(repeating: 0.0)
            var target = marker.transform
            target.scale = SIMD3<Float>(repeating: 1.0)
            marker.move(
                to: target,
                relativeTo: rootEntity,
                duration: 0.15,
                timingFunction: .easeOut
            )
        }
    }

    /// Switches which marker (if any) is shown in the active gold style.
    /// Pass `nil` when the dragged piece is not over a legal square.
    func setActiveMarker(_ square: Square?) {
        guard square != activeMarkerSquare else { return }

        if let prev = activeMarkerSquare, let marker = legalMarkers[prev] {
            applyMarkerStyle(.legal, to: marker)
        }
        activeMarkerSquare = square
        if let cur = square, let marker = legalMarkers[cur] {
            applyMarkerStyle(.active, to: marker)
        }
    }

    /// Removes every legal-move marker. Called when a drag ends or is cancelled.
    func clearLegalMoveMarkers() {
        for (_, marker) in legalMarkers {
            marker.removeFromParent()
        }
        legalMarkers.removeAll()
        activeMarkerSquare = nil
    }

    private enum MarkerStyle {
        case legal
        case active
    }

    private func makeMarker(for square: Square, active: Bool) -> ModelEntity {
        let radius: Float = 0.012             // 12 mm (≈ 20% of a 60 mm square)
        let height: Float = 0.0015            // 1.5 mm
        let mesh = MeshResource.generateCylinder(height: height, radius: radius)
        let material = active
            ? ChessMaterials.activeMoveMarkerMaterial()
            : ChessMaterials.legalMoveMarkerMaterial()
        let marker = ModelEntity(mesh: mesh, materials: [material])

        var pos = BoardSurface.position(for: square)
        // Stack the marker just above the square's top face.
        pos.y = SceneMetrics.squareThickness + height / 2 + 0.0005
        marker.position = pos
        marker.name = "LegalMarker_\(square.algebraic)"
        // Grow the active marker a touch so the highlight is unmistakable.
        if active {
            marker.scale = SIMD3<Float>(repeating: 1.3)
        }
        return marker
    }

    private func applyMarkerStyle(_ style: MarkerStyle, to marker: ModelEntity) {
        let material: UnlitMaterial
        let scale: Float
        switch style {
        case .legal:
            material = ChessMaterials.legalMoveMarkerMaterial()
            scale = 1.0
        case .active:
            material = ChessMaterials.activeMoveMarkerMaterial()
            scale = 1.3
        }
        marker.model?.materials = [material]
        var target = marker.transform
        target.scale = SIMD3<Float>(repeating: scale)
        marker.move(
            to: target,
            relativeTo: rootEntity,
            duration: 0.10,
            timingFunction: .easeOut
        )
    }

    // MARK: - Helpers

    /// World-position above a square's surface — base of the piece sits on the
    /// top face of the square box (very slightly above the frame).
    private func surfacePosition(for square: Square) -> SIMD3<Float> {
        var pos = BoardSurface.position(for: square)
        pos.y = SceneMetrics.squareThickness
        return pos
    }

    // MARK: - TabletopGame.RenderDelegate

    func onUpdate(
        timeInterval: Double,
        snapshot: TableSnapshot,
        visualState: TableVisualState
    ) {
        // No-op: positions are driven by animateMove, not by TabletopKit's
        // visualState (which is in world coords and would clash with our
        // root-local placement).
    }

    func updateRootPose(_ pose: Pose3D) {
        // No-op: the scene host owns the root's world transform (so it can
        // keep the board at user-comfortable height and let the user drag it).
    }
}
