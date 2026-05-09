import SwiftUI
import RealityKit
import TabletopKit
import Spatial

/// SwiftUI host for the chess scene.
///
/// Builds the table, instantiates a `MatchCoordinator` from
/// `AppModel.matchSettings`, and routes pinch-and-drag gestures to either:
///   * the **board frame** → drag the entire scene root in 3D (placement),
///   * **a piece** → drag-and-drop with snap-to-square + rules validation.
///
/// The opponent is currently `RandomMoveAIEngine` so we can validate the full
/// loop (drag → rules → engine → animation) without depending on Stockfish's
/// NNUE network. Swap to `StockfishEngine()` in `makeAI()` later.
@MainActor
struct ChessSceneView: View {

    @Environment(AppModel.self) private var appModel

    @State private var coordinator: MatchCoordinator?
    @State private var renderer: ChessRenderer?
    /// Anchored to the user's head, used to raycast from the eye through the
    /// gaze onto the board plane during piece drags. This is the only
    /// reliable way to map gaze ↔ board square from oblique view angles.
    @State private var headAnchor: AnchorEntity?

    @State private var dragOriginPosition: SIMD3<Float>?      // board placement
    @State private var pieceDrag: PieceDragState?              // piece drag

    var body: some View {
        RealityView { content, attachments in
            await PieceMeshFactory.preload()

            let rules = ChessKitRulesEngine()
            let ai = makeAI(rules: rules)
            let humanSide = appModel.matchSettings.resolvedHumanSide()

            let whiteController: MatchCoordinator.SideController =
                humanSide == .white ? .human : .ai(appModel.matchSettings.aiSettings)
            let blackController: MatchCoordinator.SideController =
                humanSide == .black ? .human : .ai(appModel.matchSettings.aiSettings)

            let match = Match()
            let coord = MatchCoordinator(
                match: match,
                rules: rules,
                ai: ai,
                white: whiteController,
                black: blackController
            )

            let renderer = ChessRenderer()
            let table = ChessTable(id: EquipmentIdentifier(1))

            var setup = TableSetup(tabletop: table)
            let whiteSeat = ChessSeat(id: TableSeatIdentifier(1), side: .white)
            let blackSeat = ChessSeat(id: TableSeatIdentifier(2), side: .black)
            setup.add(seat: whiteSeat)
            setup.add(seat: blackSeat)

            Self.populatePieces(
                into: &setup,
                renderer: renderer,
                tableID: table.id,
                idStart: 100
            )

            let game = TabletopGame(tableSetup: setup)
            game.claimSeat(humanSide == .white ? whiteSeat : blackSeat)
            game.addRenderDelegate(renderer)

            // Route every applied move (human or AI) through the renderer so
            // the visual stays in sync with the authoritative `Match`.
            coord.moveAppliedHandler = { [weak renderer] move in
                renderer?.animateMove(move)
            }

            // On New Game, wipe the visual pieces and re-seed them from the
            // standard starting position. The coordinator has already reset
            // its `Match`; we only need to re-create the visuals here.
            coord.matchResetHandler = { [weak renderer] in
                guard let renderer else { return }
                renderer.clearAllPieces()
                Self.repopulatePieces(
                    renderer: renderer,
                    tableID: table.id,
                    idStart: 200
                )
            }

            renderer.rootEntity.position = SIMD3<Float>(
                0,
                SceneMetrics.defaultTableHeight,
                SceneMetrics.defaultTableDepth
            )
            content.add(renderer.rootEntity)

            // Track the user's head pose so the drag handler can raycast
            // from the eye through the gaze onto the board plane. Without
            // this, `value.location3D` from a piece-targeted drag projects
            // onto a plane perpendicular to the *initial* gaze, which
            // squashes the Z component on oblique views and makes long
            // moves (queen d1 → h5) physically unreachable.
            let head = AnchorEntity(.head, trackingMode: .predicted)
            content.add(head)
            self.headAnchor = head

            // Anchor the floating HUD to the right of the board, slightly
            // above the table surface, tilted up so it faces the user.
            if let hud = attachments.entity(for: "match-hud") {
                hud.position = SIMD3<Float>(
                    SceneMetrics.boardOuterSide / 2 + 0.10,
                    0.18,
                    0
                )
                hud.transform.rotation = simd_quatf(
                    angle: -.pi / 6,         // tilt back ~30° toward the user
                    axis: SIMD3<Float>(1, 0, 0)
                )
                renderer.rootEntity.addChild(hud)
            }

            _ = content.subscribe(to: SceneEvents.Update.self) { @MainActor event in
                game.update(deltaTime: event.deltaTime)
            }

            // Stash for the gesture handlers.
            self.coordinator = coord
            self.renderer = renderer

            coord.start()
        } attachments: {
            Attachment(id: "match-hud") {
                if let coordinator {
                    MatchHUDView(coordinator: coordinator)
                }
            }
        }
        .gesture(combinedDrag)
    }

    /// Adds the 32 starting-position pieces and registers them both with
    /// the renderer and with TabletopKit's `TableSetup`. Used at first
    /// scene build.
    private static func populatePieces(
        into setup: inout TableSetup,
        renderer: ChessRenderer,
        tableID: EquipmentIdentifier,
        idStart: Int
    ) {
        var nextID = idStart
        for square in Square.all {
            guard let piece = Position.standardStart[square] else { continue }
            let equipment = ChessPieceEquipment(
                id: EquipmentIdentifier(nextID),
                piece: piece,
                square: square,
                parentID: tableID
            )
            setup.add(equipment: equipment)
            renderer.placePiece(equipment, on: square)
            nextID += 1
        }
    }

    /// Re-creates only the renderer-side visuals at the standard starting
    /// position. Used by `MatchCoordinator.matchResetHandler` on New Game —
    /// the existing TabletopKit equipment list is left alone (we don't
    /// drive the scene through its visualState anyway).
    private static func repopulatePieces(
        renderer: ChessRenderer,
        tableID: EquipmentIdentifier,
        idStart: Int
    ) {
        var nextID = idStart
        for square in Square.all {
            guard let piece = Position.standardStart[square] else { continue }
            let equipment = ChessPieceEquipment(
                id: EquipmentIdentifier(nextID),
                piece: piece,
                square: square,
                parentID: tableID
            )
            renderer.placePiece(equipment, on: square)
            nextID += 1
        }
    }

    // MARK: - AI factory (single line to swap to Stockfish)

    private func makeAI(rules: any RulesEngine) -> any ChessAIEngine {
        // TODO: when NNUE is bundled, return `StockfishEngine()`.
        RandomMoveAIEngine(rules: rules)
    }

    // MARK: - Combined drag

    /// One physical gesture, dispatched to either piece or board placement
    /// based on which entity SwiftUI hit-tested under the user's pinch.
    private var combinedDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToAnyEntity()
            .onChanged { value in
                if value.entity.components[ChessPieceComponent.self] != nil {
                    onPieceDragChanged(value)
                } else if value.entity.name == BoardSurface.frameName {
                    onBoardPlacementChanged(value)
                }
            }
            .onEnded { value in
                if value.entity.components[ChessPieceComponent.self] != nil {
                    onPieceDragEnded(value)
                } else if value.entity.name == BoardSurface.frameName {
                    onBoardPlacementEnded(value)
                }
            }
    }

    // MARK: - Piece drag

    private func onPieceDragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let coordinator, let renderer,
              let comp = value.entity.components[ChessPieceComponent.self]
        else { return }

        // Only the side-to-move's human pieces are draggable; ignore the rest.
        if pieceDrag == nil {
            guard isHumanTurnAndOwnsPiece(comp, coordinator: coordinator) else { return }
            let legal = coordinator.legalMoves(from: comp.square)
            let destinations = Set(legal.map(\.to))
            pieceDrag = PieceDragState(
                entity: value.entity,
                originSquare: comp.square,
                originLocalPosition: value.entity.position,
                legalDestinations: destinations
            )
            renderer.lift(value.entity)
            renderer.showLegalMoveMarkers(Array(destinations))
            // Stop hover highlighting any other entity for the duration
            // of this drag — keeps the gaze "ghost" from making the king
            // / a different piece / the frame light up while you move.
            renderer.suppressHover(except: value.entity)
        }

        guard let drag = pieceDrag, drag.entity === value.entity,
              let parent = value.entity.parent else { return }

        // Place the piece by **raycasting from the user's eye through the
        // current gaze onto the board's horizontal plane**. This is the
        // proper "look-and-slide" tabletop projection — independent of
        // view angle, so a queen-side diagonal across the whole board
        // works even from a steeply oblique perspective.
        //
        // SwiftUI's `value.location3D` on a piece-targeted drag projects
        // onto a plane perpendicular to the *initial* gaze direction.
        // From a tilted view that plane isn't horizontal, so movement
        // along the table's depth axis gets compressed. By replacing it
        // with our own gaze→table-plane intersection (using the user's
        // head transform from `AnchorEntity(.head)`), we recover the
        // intuitive "the piece sits where I'm looking" behaviour at any
        // angle.
        if let target = boardPlaneIntersection(for: value, parent: parent) {
            let halfBoard = SceneMetrics.boardPlayableSide / 2
            let edgeSlack: Float = 0.03
            let liftedY = SceneMetrics.squareThickness + ChessRenderer.liftHeight
            value.entity.position = SIMD3<Float>(
                max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, target.x)),
                liftedY,
                max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, target.z))
            )
        }

        // Live "current target" highlight: the legal square (if any) that
        // the piece's centre is currently above.
        let candidate = BoardSurface.square(forBoardLocalPosition: value.entity.position)
        if let candidate, drag.legalDestinations.contains(candidate) {
            renderer.setActiveMarker(candidate)
        } else {
            renderer.setActiveMarker(nil)
        }
    }

    /// Casts a ray from the user's head through the current gaze point
    /// (`value.location3D` in scene space) and returns where it intersects
    /// the board's surface plane, in `parent`-local coordinates. `nil` if
    /// the head anchor isn't tracked yet, the ray points away from the
    /// table, or the math degenerates (e.g. parallel ray).
    private func boardPlaneIntersection(
        for value: EntityTargetValue<DragGesture.Value>,
        parent: Entity
    ) -> SIMD3<Float>? {
        guard let head = headAnchor else { return nil }

        let headWorld = head.position(relativeTo: nil)
        let gazeScene = value.convert(value.location3D, from: .local, to: .scene)
        let gazeWorld = SIMD3<Float>(
            Float(gazeScene.x), Float(gazeScene.y), Float(gazeScene.z)
        )

        var rayDir = gazeWorld - headWorld
        let length = simd_length(rayDir)
        guard length > 1e-4 else { return nil }
        rayDir /= length

        // Solve for t in (head + t * dir).y == boardPlaneY (world).
        let boardPlaneY = parent.position(relativeTo: nil).y
            + SceneMetrics.squareThickness
            + ChessRenderer.liftHeight
        // Need the ray to actually point toward (downward from above) the table.
        guard abs(rayDir.y) > 1e-4 else { return nil }
        let t = (boardPlaneY - headWorld.y) / rayDir.y
        guard t > 0 else { return nil }

        let hitWorld = headWorld + rayDir * t
        return parent.convert(position: hitWorld, from: nil)
    }

    private func onPieceDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let coordinator, let renderer,
              let drag = pieceDrag,
              drag.entity === value.entity else {
            renderer?.clearLegalMoveMarkers()
            renderer?.restoreHover()
            pieceDrag = nil
            return
        }

        let dropLocal = value.entity.position
        let candidate = BoardSurface.square(forBoardLocalPosition: dropLocal)

        if let candidate, drag.legalDestinations.contains(candidate) {
            let move = legalMove(from: drag.originSquare, to: candidate, coordinator: coordinator)
            if let move {
                coordinator.submitHumanMove(move)
            } else {
                renderer.snapBack(value.entity)
            }
        } else {
            renderer.snapBack(value.entity)
        }
        renderer.clearLegalMoveMarkers()
        renderer.restoreHover()
        pieceDrag = nil
    }

    private func isHumanTurnAndOwnsPiece(
        _ comp: ChessPieceComponent,
        coordinator: MatchCoordinator
    ) -> Bool {
        guard !coordinator.match.status.isGameOver else { return false }
        guard !coordinator.isAIThinking else { return false }
        return coordinator.match.currentPosition.sideToMove == comp.color
    }

    /// Picks the canonical legal `Move` matching `from → to`. Prefers a
    /// promotion-to-queen variant when present (auto-promotion in MVP).
    private func legalMove(
        from: Square,
        to: Square,
        coordinator: MatchCoordinator
    ) -> Move? {
        let candidates = coordinator.legalMoves(from: from).filter { $0.to == to }
        if candidates.isEmpty { return nil }
        if let promo = candidates.first(where: { $0.promotion == .queen }) {
            return promo
        }
        return candidates.first
    }

    // MARK: - Board placement drag

    private func onBoardPlacementChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let root = sceneRoot(containing: value.entity) else { return }
        let startScene = value.convert(value.startLocation3D, from: .local, to: .scene)
        let nowScene = value.convert(value.location3D, from: .local, to: .scene)
        let delta = nowScene - startScene

        if dragOriginPosition == nil {
            dragOriginPosition = root.position
        }
        guard let origin = dragOriginPosition else { return }
        root.position = SIMD3<Float>(
            origin.x + Float(delta.x),
            origin.y + Float(delta.y),
            origin.z + Float(delta.z)
        )
    }

    private func onBoardPlacementEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        dragOriginPosition = nil
    }

    private func sceneRoot(containing entity: Entity) -> Entity? {
        var node: Entity? = entity
        while let n = node {
            if n.name == "ChessSceneRoot" { return n }
            node = n.parent
        }
        return nil
    }
}

// MARK: - Helpers

/// Per-active-piece-drag state. Captured on the first onChanged tick so the
/// next ticks have an origin to translate from and a legality whitelist.
private struct PieceDragState {
    let entity: Entity
    let originSquare: Square
    let originLocalPosition: SIMD3<Float>
    let legalDestinations: Set<Square>
}
