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

    @State private var dragOriginPosition: SIMD3<Float>?      // board placement
    @State private var pieceDrag: PieceDragState?              // piece drag

    var body: some View {
        RealityView { content in
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

            var nextID = 100
            for square in Square.all {
                guard let piece = Position.standardStart[square] else { continue }
                let equipment = ChessPieceEquipment(
                    id: EquipmentIdentifier(nextID),
                    piece: piece,
                    square: square,
                    parentID: table.id
                )
                setup.add(equipment: equipment)
                renderer.placePiece(equipment, on: square)
                nextID += 1
            }

            let game = TabletopGame(tableSetup: setup)
            game.claimSeat(humanSide == .white ? whiteSeat : blackSeat)
            game.addRenderDelegate(renderer)

            // Route every applied move (human or AI) through the renderer so
            // the visual stays in sync with the authoritative `Match`.
            coord.moveAppliedHandler = { [weak renderer] move in
                renderer?.animateMove(move)
            }

            renderer.rootEntity.position = SIMD3<Float>(
                0,
                SceneMetrics.defaultTableHeight,
                SceneMetrics.defaultTableDepth
            )
            content.add(renderer.rootEntity)

            _ = content.subscribe(to: SceneEvents.Update.self) { @MainActor event in
                game.update(deltaTime: event.deltaTime)
            }

            // Stash for the gesture handlers.
            self.coordinator = coord
            self.renderer = renderer

            coord.start()
        }
        .gesture(combinedDrag)
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
            // Cache legal destinations so onEnded doesn't have to recompute,
            // and capture origin for the snap-back path.
            let legal = coordinator.legalMoves(from: comp.square)
            let destinations = Set(legal.map(\.to))
            pieceDrag = PieceDragState(
                entity: value.entity,
                originSquare: comp.square,
                originLocalPosition: value.entity.position,
                legalDestinations: destinations
            )
            renderer.lift(value.entity)
            // Show targeting affordance for every legal destination.
            renderer.showLegalMoveMarkers(Array(destinations))
        }

        guard let drag = pieceDrag, drag.entity === value.entity,
              let parent = value.entity.parent else { return }

        // Tabletop "look-and-slide" drag — the canonical pattern Apple uses
        // in BotanistGame, ChartingPawns and the visionOS Solitaire sample.
        // The piece's X-Z follows the **absolute** 3D location of the
        // gesture (= the user's gaze on Vision Pro, the cursor in the
        // simulator) projected onto the board plane. Y is pinned to a
        // fixed lift height.
        //
        // Why absolute and not delta: a delta-based drag accumulates the
        // gesture's translation3D from the start point, which in the
        // simulator saturates as the cursor approaches the edges of the
        // screen — long diagonals (queen d1 → h5 from a low angle) become
        // physically impossible because translation3D can't grow past
        // what the cursor can travel. Tracking the absolute target each
        // frame side-steps that: the piece moves to wherever you're
        // currently looking on the board, no matter how far the gaze has
        // travelled.
        //
        // X/Z are clamped slightly outside the playable area so the piece
        // can still hover on the very edge squares (a/h files, ranks 1/8)
        // even if the user's gaze drifts a bit past them.
        let nowScene = value.convert(value.location3D, from: .local, to: .scene)
        let nowLocal = parent.convert(
            position: SIMD3<Float>(Float(nowScene.x), Float(nowScene.y), Float(nowScene.z)),
            from: nil
        )
        let halfBoard = SceneMetrics.boardPlayableSide / 2
        let edgeSlack: Float = 0.03   // 3 cm of overshoot tolerance
        let liftedY = SceneMetrics.squareThickness + ChessRenderer.liftHeight
        value.entity.position = SIMD3<Float>(
            max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, nowLocal.x)),
            liftedY,
            max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, nowLocal.z))
        )
        _ = drag    // keep `drag` referenced; legality look-up still uses it below

        // Live "current target" highlight: the legal square (if any) that the
        // piece's centre is currently above.
        let candidate = BoardSurface.square(forBoardLocalPosition: value.entity.position)
        if let candidate, drag.legalDestinations.contains(candidate) {
            renderer.setActiveMarker(candidate)
        } else {
            renderer.setActiveMarker(nil)
        }
    }

    private func onPieceDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let coordinator, let renderer,
              let drag = pieceDrag,
              drag.entity === value.entity else {
            renderer?.clearLegalMoveMarkers()
            pieceDrag = nil
            return
        }

        let dropLocal = value.entity.position
        let candidate = BoardSurface.square(forBoardLocalPosition: dropLocal)

        if let candidate, drag.legalDestinations.contains(candidate) {
            // Submit. animateMove(...) will snap the piece to the square's
            // exact centre via the moveAppliedHandler callback.
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
