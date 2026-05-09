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
    /// Small white dots over each legal-destination square, visible during a
    /// drag so the user knows where the piece can land.
    private var legalMarkers: [Square: ModelEntity] = [:]
    /// Full-square gold overlay shown on whichever legal square is currently
    /// under the dragged piece. The square shape (rather than a scaled-up
    /// dot) lets the overlay stick out around any piece sitting on the
    /// destination, so capture targets are unmistakable.
    private var activeOverlay: ModelEntity?
    /// Square that `activeOverlay` is currently anchored to. `nil` when the
    /// piece isn't over any legal target.
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

    /// Spawns a small white dot over every legal-destination square so the
    /// user can see where the picked-up piece can land. Markers fade-and-
    /// scale-in over 150 ms.
    func showLegalMoveMarkers(_ squares: [Square]) {
        clearLegalMoveMarkers()
        for square in squares {
            let marker = makeLegalDot(at: square)
            legalMarkers[square] = marker
            rootEntity.addChild(marker)

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

    /// Anchors a full-square gold overlay to whichever legal square the
    /// dragged piece is currently above. Pass `nil` when the piece is not
    /// over any legal target. The overlay covers the square edge-to-edge,
    /// so on a capture move it sticks out around the opponent's piece —
    /// the user can tell at a glance "I'm targeting *this* enemy".
    func setActiveMarker(_ square: Square?) {
        guard square != activeMarkerSquare else { return }
        activeMarkerSquare = square

        activeOverlay?.removeFromParent()
        activeOverlay = nil

        if let cur = square {
            let overlay = makeActiveOverlay(at: cur)
            rootEntity.addChild(overlay)
            activeOverlay = overlay

            // Pop-in: start narrower than full size, expand to fit the
            // square. Y-scale stays at 1 so the overlay's tiny thickness
            // doesn't visibly grow.
            overlay.transform.scale = SIMD3<Float>(0.6, 1.0, 0.6)
            var target = overlay.transform
            target.scale = SIMD3<Float>(repeating: 1.0)
            overlay.move(
                to: target,
                relativeTo: rootEntity,
                duration: 0.10,
                timingFunction: .easeOut
            )
        }
    }

    /// Removes every legal-move marker and the active overlay. Called when
    /// a drag ends or is cancelled.
    func clearLegalMoveMarkers() {
        for (_, marker) in legalMarkers {
            marker.removeFromParent()
        }
        legalMarkers.removeAll()
        activeOverlay?.removeFromParent()
        activeOverlay = nil
        activeMarkerSquare = nil
    }

    private func makeLegalDot(at square: Square) -> ModelEntity {
        let radius: Float = 0.012        // 12 mm — ~20% of a 60 mm square
        let height: Float = 0.0015       // 1.5 mm
        let mesh = MeshResource.generateCylinder(height: height, radius: radius)
        let entity = ModelEntity(
            mesh: mesh,
            materials: [ChessMaterials.legalMoveMarkerMaterial()]
        )
        var pos = BoardSurface.position(for: square)
        pos.y = SceneMetrics.squareThickness + height / 2 + 0.0005
        entity.position = pos
        entity.name = "LegalDot_\(square.algebraic)"
        return entity
    }

    private func makeActiveOverlay(at square: Square) -> ModelEntity {
        // Slightly inset from the square's edges to avoid z-fight with the
        // wooden frame's inner border.
        let size = SceneMetrics.squareSize - 0.002
        let height: Float = 0.0015
        let mesh = MeshResource.generateBox(
            size: [size, height, size],
            cornerRadius: 0.003
        )
        let entity = ModelEntity(
            mesh: mesh,
            materials: [ChessMaterials.activeMoveMarkerMaterial()]
        )
        var pos = BoardSurface.position(for: square)
        // Lift slightly *above* the legal dot so the overlay covers it.
        pos.y = SceneMetrics.squareThickness + height / 2 + 0.0010
        entity.position = pos
        entity.name = "ActiveOverlay_\(square.algebraic)"
        return entity
    }

    // MARK: - Hover suppression during drag

    /// Entities whose `HoverEffectComponent` was temporarily removed by
    /// `suppressHover(except:)` so they can be restored on `restoreHover()`.
    private var hoverSuppressedEntities: [Entity] = []

    /// Removes `HoverEffectComponent` from every entity in the scene tree
    /// EXCEPT `keep`. Used while a drag is in progress so the gaze passing
    /// over other pieces / the wooden frame doesn't make them light up
    /// distractingly.
    func suppressHover(except keep: Entity?) {
        hoverSuppressedEntities.removeAll(keepingCapacity: true)
        enumerateAllEntities(in: rootEntity) { entity in
            guard entity !== keep else { return }
            if entity.components[HoverEffectComponent.self] != nil {
                entity.components.remove(HoverEffectComponent.self)
                hoverSuppressedEntities.append(entity)
            }
        }
    }

    /// Re-adds the default `HoverEffectComponent` to every entity that
    /// `suppressHover(except:)` stripped.
    func restoreHover() {
        for entity in hoverSuppressedEntities {
            entity.components.set(HoverEffectComponent())
        }
        hoverSuppressedEntities.removeAll(keepingCapacity: true)
    }

    private func enumerateAllEntities(in entity: Entity, _ body: (Entity) -> Void) {
        body(entity)
        for child in entity.children {
            enumerateAllEntities(in: child, body)
        }
    }

    // MARK: - Reset

    /// Clears every piece entity and any active marker. Used when the
    /// coordinator starts a new game so the scene host can repopulate
    /// from `Position.standardStart` cleanly.
    func clearAllPieces() {
        for (_, entity) in pieceEntities {
            entity.removeFromParent()
        }
        pieceEntities.removeAll()
        pieceBySquare.removeAll()
        clearLegalMoveMarkers()
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
