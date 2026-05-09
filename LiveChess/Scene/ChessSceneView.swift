import SwiftUI
import RealityKit
import TabletopKit

/// SwiftUI host for the chess scene.
///
/// Reads `AppModel.activeSession` at first appearance to figure out which
/// match flavour to render — local (human vs Stockfish via
/// `MatchCoordinator`) or online (human vs Lichess opponent via
/// `LichessMatchSession`). Both cases share the same renderer,
/// drag-handler, and HUD attachment plumbing through the
/// `MatchSession` protocol.
///
/// Move flow:
///   * **piece drag** → `session.legalMoves(from:)` for highlights →
///     `session.submitMove(_:)` on legal drop. The session decides what
///     happens next (local AI computes; Lichess POSTs to the Board API).
///   * **board frame drag** → physical re-positioning of the board in the
///     immersive space. Same UX whether the match is local or online.
@MainActor
struct ChessSceneView: View {

    @Environment(AppModel.self) private var appModel

    /// `any MatchSession` — set in the make closure after we resolve
    /// `appModel.activeSession`. Used by the drag handler and the HUD
    /// attachment closure.
    @State private var session: (any MatchSession)?
    @State private var renderer: ChessRenderer?

    @State private var dragOriginPosition: SIMD3<Float>?      // board placement
    @State private var pieceDrag: PieceDragState?              // piece drag

    var body: some View {
        RealityView { content, attachments in
            await PieceMeshFactory.preload()

            // Resolve which session we're rendering. The lobby is supposed
            // to have set this before opening the immersive space; if it
            // somehow didn't, fall back to a fresh local match against
            // Stockfish so the scene at least boots cleanly.
            let active = appModel.activeSession ?? .local(Self.makeDefaultLocalCoordinator(
                matchSettings: appModel.matchSettings
            ))
            let session: any MatchSession = active.session

            // Render-side construction. Same shape for both flavours; the
            // session abstraction keeps the differences out of the make
            // closure.
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

            let humanSide = Self.humanSide(for: active, settings: appModel.matchSettings)
            let game = TabletopGame(tableSetup: setup)
            game.claimSeat(humanSide == .white ? whiteSeat : blackSeat)
            game.addRenderDelegate(renderer)

            // Wire renderer hooks via the shared MatchSession protocol so
            // both `MatchCoordinator` and `LichessMatchSession` drive the
            // same animation pipeline.
            session.moveAppliedHandler = { [weak renderer] move in
                renderer?.animateMove(move)
            }
            // matchResetHandler fires on local "Nuova partita" (resets to
            // standard start), on Lichess `gameFull` (resets to game's
            // initialFen, then the session re-applies moves through the
            // moveAppliedHandler one by one), and on a Lichess optimistic-
            // move rollback (reverts to the pre-move position). All three
            // share the same shape: clear the board's piece entities and
            // re-seed them from whatever position the session is now at.
            session.matchResetHandler = { [weak renderer, weak session] in
                guard let renderer, let session else { return }
                renderer.clearAllPieces()
                Self.repopulatePieces(
                    from: session.match.currentPosition,
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

            // Stash for the gesture handlers + HUD attachment closure.
            self.session = session
            self.renderer = renderer

            // Kick off whichever flow this is.
            switch active {
            case .local(let coord):
                coord.start()
            case .online(let online):
                await online.start()
            }
        } attachments: {
            Attachment(id: "match-hud") {
                if let session = appModel.activeSession {
                    switch session {
                    case .local(let coord):
                        LocalMatchHUDView(coordinator: coord)
                    case .online(let online):
                        OnlineMatchHUDView(session: online)
                    }
                }
            }
        }
        .gesture(combinedDrag)
        .onDisappear {
            // Tear down the online connection so we don't keep the game
            // stream open (and our event-stream slot busy) when the
            // immersive space closes.
            if let session = appModel.activeSession,
               case .online(let online) = session {
                Task { await online.disconnect() }
            }
            appModel.activeSession = nil
        }
    }

    /// Determines which seat the human is on, based on the session
    /// flavour: the lobby's `humanColor` setting for local games, or
    /// the Lichess-assigned colour for online games.
    private static func humanSide(
        for active: ActiveSession,
        settings: MatchSettings
    ) -> Side {
        switch active {
        case .local: return settings.resolvedHumanSide()
        case .online(let online): return online.humanColor
        }
    }

    /// Fallback used only if the immersive opens with no `activeSession`
    /// pre-set. Mirrors what the lobby's "Apri scacchiera" button would
    /// have built — the human-vs-Stockfish loop with current settings.
    private static func makeDefaultLocalCoordinator(
        matchSettings: MatchSettings
    ) -> MatchCoordinator {
        let rules = ChessKitRulesEngine()
        let humanSide = matchSettings.resolvedHumanSide()
        let whiteController: MatchCoordinator.SideController =
            humanSide == .white ? .human : .ai(matchSettings.aiSettings)
        let blackController: MatchCoordinator.SideController =
            humanSide == .black ? .human : .ai(matchSettings.aiSettings)
        return MatchCoordinator(
            match: Match(),
            rules: rules,
            ai: StockfishEngine(),
            white: whiteController,
            black: blackController
        )
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

    /// Re-creates the renderer-side visuals from an arbitrary position.
    /// Used by `MatchSession.matchResetHandler` for:
    ///   * local "Nuova partita" (`position` = standard start)
    ///   * Lichess `gameFull` reconnect (`position` = game's initial
    ///     FEN — the session then re-applies moves through
    ///     `moveAppliedHandler` so the renderer animates each one)
    ///   * Lichess optimistic-move rollback (`position` = the pre-move
    ///     snapshot — no animations needed; the board snaps back to the
    ///     state before the rejected POST).
    private static func repopulatePieces(
        from position: Position,
        renderer: ChessRenderer,
        tableID: EquipmentIdentifier,
        idStart: Int
    ) {
        var nextID = idStart
        for square in Square.all {
            guard let piece = position[square] else { continue }
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
        guard let session, let renderer,
              let comp = value.entity.components[ChessPieceComponent.self]
        else { return }

        // Only the side-to-move's human pieces are draggable; ignore the rest.
        if pieceDrag == nil {
            guard isHumanPickup(comp, in: session) else { return }
            let legal = session.legalMoves(from: comp.square)
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

        // Standard visionOS tabletop drag: take the gesture's projected 3D
        // location (visionOS picks an appropriate gaze-tracking plane
        // through the dragged entity), convert to the scene then to the
        // root-local frame, then pin Y to the lift height so the piece
        // slides along the board surface instead of flying up. X / Z are
        // clamped to the playable area + a small slack so a hand drift
        // past the edge doesn't fling the piece into the void.
        let scenePoint = value.convert(value.location3D, from: .local, to: .scene)
        let local = parent.convert(
            position: SIMD3<Float>(Float(scenePoint.x), Float(scenePoint.y), Float(scenePoint.z)),
            from: nil
        )
        let halfBoard = SceneMetrics.boardPlayableSide / 2
        let edgeSlack: Float = 0.03
        let liftedY = SceneMetrics.squareThickness + ChessRenderer.liftHeight
        value.entity.position = SIMD3<Float>(
            max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, local.x)),
            liftedY,
            max(-halfBoard - edgeSlack, min(halfBoard + edgeSlack, local.z))
        )

        // Live "current target" highlight: the legal square (if any) that
        // the piece's centre is currently above.
        let candidate = BoardSurface.square(forBoardLocalPosition: value.entity.position)
        if let candidate, drag.legalDestinations.contains(candidate) {
            renderer.setActiveMarker(candidate)
        } else {
            renderer.setActiveMarker(nil)
        }
    }

    private func onPieceDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let session, let renderer,
              let drag = pieceDrag,
              drag.entity === value.entity else {
            renderer?.clearLegalMoveMarkers()
            renderer?.restoreHover()
            pieceDrag = nil
            return
        }

        let dropLocal = value.entity.position
        let candidate = BoardSurface.square(forBoardLocalPosition: dropLocal)

        if let candidate, drag.legalDestinations.contains(candidate),
           let move = legalMove(from: drag.originSquare, to: candidate, in: session) {
            Task { await session.submitMove(move) }
        } else {
            renderer.snapBack(value.entity)
        }
        renderer.clearLegalMoveMarkers()
        renderer.restoreHover()
        pieceDrag = nil
    }

    /// True iff the dragged piece belongs to the side-to-move AND it's
    /// the human player's turn (no AI computing locally, no remote-stream
    /// pause).
    private func isHumanPickup(
        _ comp: ChessPieceComponent,
        in session: any MatchSession
    ) -> Bool {
        guard session.isHumanTurn else { return false }
        return session.match.currentPosition.sideToMove == comp.color
    }

    /// Picks the canonical legal `Move` matching `from → to`. Prefers a
    /// promotion-to-queen variant when present (auto-promotion in MVP).
    private func legalMove(
        from: Square,
        to: Square,
        in session: any MatchSession
    ) -> Move? {
        let candidates = session.legalMoves(from: from).filter { $0.to == to }
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
