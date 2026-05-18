import Foundation
import RealityKit
import TabletopKit
import Spatial
import UIKit
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

    /// Puzzle-hint overlay (`pulseHintSquare(_:)`). Separate from
    /// `activeOverlay` so a hint pulse can coexist with the player
    /// already dragging a piece.
    private var hintOverlay: ModelEntity?
    /// Task that fades / removes the hint overlay after its beat.
    /// Cancelled on re-press so a new hint doesn't clear too early.
    private var hintTask: Task<Void, Never>?

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
    /// User-picked material configuration applied to every piece
    /// built through this renderer. `nil` (the default) keeps the
    /// USDZ-baked materials. The scene host sets this on construction
    /// from the active `PieceCustomization`. Per-piece override
    /// materials are derived per-side at `placePiece` time, since the
    /// preset's tint differs for white vs black.
    var pieceMaterial: PieceMaterial?

    /// Live-applies a new piece-material configuration to every piece
    /// already on the board, without rebuilding the entity tree. Used
    /// by the scene host's `.onChange(pieceCustomization)` so an open
    /// game updates its skin the moment the user moves a colour
    /// picker in the lobby sheet.
    func setPieceMaterial(_ config: PieceMaterial) {
        self.pieceMaterial = config
        for (_, entity) in pieceEntities {
            guard let comp = entity.components[ChessPieceComponent.self] else { continue }
            guard let override = PieceMaterialFactory.material(for: config, side: comp.color) else {
                continue
            }
            PieceMeshFactory.applyMaterial(override, to: entity)
        }
    }

    /// Live-rebuilds the board's surface materials to match the user's
    /// full customisation (square + frame material families AND
    /// per-slot tints). Walks the four frame bars + 64 squares and
    /// swaps each `ModelComponent`'s materials with the PBR built by
    /// `PieceMaterialFactory.boardSquareMaterial / boardFrameMaterial`.
    /// No entity teardown — pieces and markers stay put.
    ///
    /// Square light/dark assignment is recomputed from the
    /// `Square_<file>_<rank>` name encoded in `BoardSurface` so the
    /// walk is self-contained (no dependency on whatever material is
    /// currently installed).
    func setBoardSurface(_ config: PieceMaterial) {
        let lightMat = PieceMaterialFactory.boardSquareMaterial(for: config, isLight: true)
        let darkMat  = PieceMaterialFactory.boardSquareMaterial(for: config, isLight: false)
        let frameMat = PieceMaterialFactory.boardFrameMaterial(for: config)

        var stack: [Entity] = [boardEntity]
        while let entity = stack.popLast() {
            if entity.name.hasPrefix("Square_"),
               var model = entity.components[ModelComponent.self] {
                let parts = entity.name.dropFirst("Square_".count).split(separator: "_")
                if parts.count == 2,
                   let file = Int(parts[0]),
                   let rank = Int(parts[1]) {
                    let isLight = !(file + rank).isMultiple(of: 2)
                    model.materials = [isLight ? lightMat : darkMat]
                    entity.components.set(model)
                }
            } else if entity.name == BoardSurface.frameName,
                      var model = entity.components[ModelComponent.self] {
                model.materials = [frameMat]
                entity.components.set(model)
            }
            stack.append(contentsOf: entity.children)
        }
    }

    func placePiece(_ equipment: ChessPieceEquipment, on square: Square) {
        let override: (any Material)? = pieceMaterial.flatMap { config in
            PieceMaterialFactory.material(for: config, side: equipment.piece.color)
        }
        let entity = PieceMeshFactory.makeEntity(
            for: equipment.piece,
            materialOverride: override
        )
        entity.name = "Piece_\(equipment.piece.color)_\(equipment.piece.kind)_\(equipment.id)"
        entity.position = surfacePosition(for: square)

        // Knights and right-side bishops are authored in the USDZ
        // facing one direction (whichever the modeller picked). The
        // result is that all knights face the h-file from white's
        // POV — visually weird because the kingside knight ends up
        // staring away from its queenside twin. Flip the right-side
        // pair (file 6 knight, file 5 bishop) 180° around Y so they
        // face their counterparts. Rotation is preserved by the
        // `glide` move animation, so a knight that moves keeps its
        // initial orientation.
        if (equipment.piece.kind == .knight && square.file == 6) ||
           (equipment.piece.kind == .bishop && square.file == 5) {
            entity.transform.rotation = simd_quatf(
                angle: .pi,
                axis: SIMD3<Float>(0, 1, 0)
            )
        }

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
        target.translation.y = SceneMetrics.boardSurfaceY + Self.liftHeight
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

    /// Pulses a gold square overlay over `square` for a short beat,
    /// then fades out. Used by `PuzzleSession.showHint()` to draw
    /// the player's eye to the source square of the next expected
    /// move without spoiling the destination.
    ///
    /// Re-presses just refresh the same overlay (the previous
    /// fade-out task is cancelled) — re-tapping Hint keeps the
    /// pulse visible without piling up duplicate entities.
    // MARK: - Review highlights

    /// Square-coloured overlay rendered under the from + to squares of
    /// the move at the currently-displayed review ply. Colour tracks
    /// the move's classification so a glance at the board tells the
    /// user whether the position came from a brilliant find, a
    /// blunder, etc. Cleared and re-built on each ply change.
    private var reviewFromOverlay: ModelEntity?
    private var reviewToOverlay: ModelEntity?

    func setReviewHighlight(from: Square?, to: Square?, quality: MoveQuality?) {
        clearReviewHighlight()
        guard let from, let to, let quality else { return }
        let material = ChessMaterials.reviewHighlightMaterial(for: quality)
        reviewFromOverlay = makeReviewOverlay(at: from, material: material)
        reviewToOverlay   = makeReviewOverlay(at: to,   material: material)
        rootEntity.addChild(reviewFromOverlay!)
        rootEntity.addChild(reviewToOverlay!)
    }

    func clearReviewHighlight() {
        reviewFromOverlay?.removeFromParent()
        reviewToOverlay?.removeFromParent()
        reviewFromOverlay = nil
        reviewToOverlay = nil
    }

    private func makeReviewOverlay(at square: Square,
                                   material: UnlitMaterial) -> ModelEntity {
        let size = SceneMetrics.squareSize - 0.002
        let height: Float = 0.0012
        let mesh = MeshResource.generateBox(
            size: [size, height, size],
            cornerRadius: 0.003
        )
        let entity = ModelEntity(mesh: mesh, materials: [material])
        var pos = BoardSurface.position(for: square)
        // Sit below the legal-move overlays (0.0015 / 0.0010 above the
        // board surface) so live-drag highlights still take precedence.
        pos.y = SceneMetrics.boardSurfaceY + height / 2 + 0.0006
        entity.position = pos
        entity.name = "ReviewHighlight_\(square.algebraic)"
        return entity
    }

    func pulseHintSquare(_ square: Square) {
        hintTask?.cancel()
        hintOverlay?.removeFromParent()

        let overlay = makeActiveOverlay(at: square)
        rootEntity.addChild(overlay)
        hintOverlay = overlay

        // Quick pop-in
        overlay.transform.scale = SIMD3<Float>(0.4, 1.0, 0.4)
        var grown = overlay.transform
        grown.scale = SIMD3<Float>(repeating: 1.0)
        overlay.move(to: grown, relativeTo: rootEntity,
                     duration: 0.15, timingFunction: .easeOut)

        // Auto-fade after 2 s so the hint doesn't linger over the
        // square the player is trying to drop into.
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            self?.hintOverlay?.removeFromParent()
            self?.hintOverlay = nil
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
        pos.y = SceneMetrics.boardSurfaceY + height / 2 + 0.0005
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
        pos.y = SceneMetrics.boardSurfaceY + height / 2 + 0.0010
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

    /// World-position on a square's playing surface — base of the
    /// piece sits flush on the board's top plane (which, post-flush
    /// rework, is the same plane for every square AND the frame).
    private func surfacePosition(for square: Square) -> SIMD3<Float> {
        var pos = BoardSurface.position(for: square)
        pos.y = SceneMetrics.boardSurfaceY
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
