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
                legalDestinations: destinations,
                lastAcceptedLocalPosition: value.entity.position
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
        if let raw = boardPlaneIntersection(for: value, parent: parent) {
            // Two-stage plausibility check before we move the piece:
            //
            // 1. **Velocity guard** — drop any frame whose projected target
            //    is more than 4 squares away from the previous accepted
            //    position. visionOS gestures fire >= 60 Hz, so 4 squares
            //    (240 mm) per tick is ~14 m/s of hand motion: well above
            //    any plausible drag, but well below the half-board jump
            //    that gaze sign-flip produces. When the projection
            //    misbehaves we simply hold the piece at its last good spot
            //    until it recovers; the user sees a brief stall instead of
            //    a teleport across the board.
            //
            // 2. **Radius cap** — defence in depth. Cap distance from the
            //    origin square at 1.5x the playable side (720 mm). The
            //    longest legal queen move is the corner-to-corner diagonal
            //    (sqrt(2)*7*60 mm ≈ 594 mm), so legal moves are unaffected;
            //    only true projection runaways get pulled back.
            let originPos = BoardSurface.position(for: drag.originSquare)
            let dxOrigin = raw.x - originPos.x
            let dzOrigin = raw.z - originPos.z
            let distFromOrigin = (dxOrigin * dxOrigin + dzOrigin * dzOrigin).squareRoot()

            let dxLast = raw.x - drag.lastAcceptedLocalPosition.x
            let dzLast = raw.z - drag.lastAcceptedLocalPosition.z
            let jumpFromLast = (dxLast * dxLast + dzLast * dzLast).squareRoot()

            let maxJump: Float = SceneMetrics.squareSize * 4
            let maxRadius: Float = SceneMetrics.boardPlayableSide * 1.5

            guard jumpFromLast <= maxJump, distFromOrigin <= maxRadius else { return }

            let halfBoard = SceneMetrics.boardPlayableSide / 2
            let edgeSlack: Float = 0.03
            let liftedY = SceneMetrics.squareThickness + ChessRenderer.liftHeight
            let xClamped = max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, raw.x))
            let zClamped = max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, raw.z))
            let newPos = SIMD3<Float>(xClamped, liftedY, zClamped)
            value.entity.position = newPos
            pieceDrag?.lastAcceptedLocalPosition = newPos
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

    /// Returns where the dragged piece should sit, in the scene root's local
    /// frame, given the current gesture state. Tries the precise gaze-ray /
    /// board-plane intersection first (using `inputDevicePose3D` when it's
    /// available, which is the visionOS-recommended path on real hardware),
    /// then falls back to a direct gaze-follow projection that the visionOS
    /// simulator can always satisfy.
    private func boardPlaneIntersection(
        for value: EntityTargetValue<DragGesture.Value>,
        parent: Entity
    ) -> SIMD3<Float>? {
        if let pose = value.gestureValue.inputDevicePose3D,
           let hit = raycastIntoBoard(pose: pose, value: value, parent: parent) {
            return hit
        }
        return gazeFollowFallback(value: value, parent: parent)
    }

    /// Proper ray-plane intersection from the user's eye through the gaze
    /// direction onto the board's horizontal plane. Reliable on real Vision
    /// Pro; in the simulator `inputDevicePose3D` may be nil (no head/gaze
    /// telemetry), so callers must have a fallback.
    private func raycastIntoBoard(
        pose: Pose3D,
        value: EntityTargetValue<DragGesture.Value>,
        parent: Entity
    ) -> SIMD3<Float>? {
        let eyeLocal = Point3D(x: pose.position.x, y: pose.position.y, z: pose.position.z)
        let eyeScene = value.convert(eyeLocal, from: .local, to: .scene)
        let eyeWorld = SIMD3<Float>(
            Float(eyeScene.x), Float(eyeScene.y), Float(eyeScene.z)
        )

        let q4 = pose.rotation.quaternion
        let qf = simd_quatf(
            ix: Float(q4.imag.x), iy: Float(q4.imag.y), iz: Float(q4.imag.z),
            r: Float(q4.real)
        )
        let forwardLocalSIMD = qf.act(SIMD3<Float>(0, 0, -1))
        let aheadLocalPoint = Point3D(
            x: Double(Float(pose.position.x) + forwardLocalSIMD.x),
            y: Double(Float(pose.position.y) + forwardLocalSIMD.y),
            z: Double(Float(pose.position.z) + forwardLocalSIMD.z)
        )
        let aheadScene = value.convert(aheadLocalPoint, from: .local, to: .scene)
        let aheadWorld = SIMD3<Float>(
            Float(aheadScene.x), Float(aheadScene.y), Float(aheadScene.z)
        )
        var forward = aheadWorld - eyeWorld
        let length = simd_length(forward)
        guard length > 1e-4 else { return nil }
        forward /= length

        let boardPlaneY = parent.position(relativeTo: nil).y
            + SceneMetrics.squareThickness
            + ChessRenderer.liftHeight

        guard abs(forward.y) > 1e-4 else { return nil }
        let t = (boardPlaneY - eyeWorld.y) / forward.y
        guard t > 0 else { return nil }

        let hitWorld = eyeWorld + forward * t
        return parent.convert(position: hitWorld, from: nil)
    }

/// Simulator-friendly fallback: take whatever the gesture reports as its
    /// 3D location (gaze on its tracking plane), convert to scene then to
    /// root-local, and return X / Z. The Y component is ignored — the caller
    /// pins the piece's Y to the lift height. This is the same baseline that
    /// shipped before the pose-aware path; it can't reach extreme corners
    /// from a steeply oblique view, but it always moves the piece, which
    /// matters more in the simulator where `inputDevicePose3D` is nil.
    private func gazeFollowFallback(
        value: EntityTargetValue<DragGesture.Value>,
        parent: Entity
    ) -> SIMD3<Float>? {
        let nowScene = value.convert(value.location3D, from: .local, to: .scene)
        let nowLocal = parent.convert(
            position: SIMD3<Float>(Float(nowScene.x), Float(nowScene.y), Float(nowScene.z)),
            from: nil
        )
        return nowLocal
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
///
/// `lastAcceptedLocalPosition` is the most recent in-board projected target
/// we actually applied to the entity, used by the per-frame velocity guard
/// in `onPieceDragChanged` to discard implausible jumps from the gaze
/// projection (the simulator's `value.location3D` plane sometimes sign-flips
/// when the gaze rotates past the perpendicular tracking plane, producing a
/// target on the opposite side of the board — without this guard the piece
/// teleports there).
private struct PieceDragState {
    let entity: Entity
    let originSquare: Square
    let originLocalPosition: SIMD3<Float>
    let legalDestinations: Set<Square>
    var lastAcceptedLocalPosition: SIMD3<Float>
}
