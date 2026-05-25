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
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// `any MatchSession` — set in the make closure after we resolve
    /// `appModel.activeSession`. Used by the drag handler and the HUD
    /// attachment closure.
    @State private var session: (any MatchSession)?
    @State private var renderer: ChessRenderer?

    /// Drives the initial chessboard placement on a detected horizontal
    /// table (Vision Pro device) and the "Move board" reposition flow.
    /// Fallbacks transparently to the hardcoded position on the
    /// simulator. Created in `make`, stashed here so the HUD's
    /// reposition button can reach it.
    @State private var placementController: PlacementController?

    @State private var dragOriginPosition: SIMD3<Float>?      // board placement
    @State private var boardRotationOrigin: simd_quatf?        // board rotation
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
            // Wire the user's chosen piece material BEFORE pieces are
            // populated so the very first frame renders with the right
            // override. Also push the board colours through so the
            // squares + frame match the user's palette from frame one.
            let customization = appModel.pieceCustomization.current
            renderer.pieceMaterial = customization
            renderer.setBoardSurface(customization)
            let table = ChessTable(id: EquipmentIdentifier(1))

            var setup = TableSetup(tabletop: table)
            let whiteSeat = ChessSeat(id: TableSeatIdentifier(1), side: .white)
            let blackSeat = ChessSeat(id: TableSeatIdentifier(2), side: .black)
            setup.add(seat: whiteSeat)
            setup.add(seat: blackSeat)

            // Seed the visual board from the session's CURRENT position,
            // not the standard start. This matters across env switches
            // mid-game: pendingReopen preserves `activeSession` so the
            // session's underlying match still holds every move played
            // so far, but the scene rebuild was hardcoding the start
            // position — making the board visually reset to move 1
            // even though the engine still thought it was move 23.
            Self.populatePieces(
                into: &setup,
                renderer: renderer,
                from: session.match.currentPosition,
                tableID: table.id,
                idStart: 100
            )

            let humanSide = Self.humanSide(for: active, settings: appModel.matchSettings)
            let game = TabletopGame(tableSetup: setup)
            game.claimSeat(humanSide == .white ? whiteSeat : blackSeat)
            game.addRenderDelegate(renderer)

            // Wire renderer hooks via the shared MatchSession protocol so
            // both `MatchCoordinator` and `LichessMatchSession` drive the
            // same animation pipeline. The handler also routes the move
            // through the SFX player — capture is detected from the
            // pre-move snapshot (the position one step before the
            // session's current one), and check/checkmate trump capture
            // so the warning cue lands when it matters.
            session.moveAppliedHandler = { [weak renderer, weak session] move in
                renderer?.animateMove(move)
                guard let session else { return }
                let positions = session.match.positions
                let wasCapture: Bool = {
                    if move.isEnPassant { return true }
                    guard positions.count >= 2 else { return false }
                    return positions[positions.count - 2][move.to] != nil
                }()
                ChessSoundPlayer.shared.play(
                    forMove: move,
                    wasCapture: wasCapture,
                    status: session.match.status
                )
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

            // Puzzle-specific renderer hook: progressive hint disclosure.
            // Stage 1 (`.source`) pulses just the piece's square. Stage 2
            // (`.fullMove`) lights up the destination too, in a distinct
            // colour, so the user reads from→to. `.none` clears any
            // overlay (used when the player makes a correct move or
            // restarts).
            if case .puzzle(let puzzle) = active {
                puzzle.hintHandler = { [weak renderer] level, move in
                    guard let renderer else { return }
                    switch level {
                    case .none:
                        renderer.clearHintOverlay()
                    case .source:
                        renderer.pulseHintSquare(move.from)
                    case .fullMove:
                        renderer.pulseHintMove(from: move.from, to: move.to)
                    }
                }
            }

            // Board orientation: rotate the whole root 180° around Y when
            // the human is playing Black, so the user sits on Black's
            // side and sees their own pieces at the bottom of the board.
            // Without this, a Black-side game would look mirrored from
            // the player's POV (kings/queens on the wrong files).
            let needsBlackPerspective = humanSide == .black
            let baseRotation: simd_quatf = needsBlackPerspective
                ? simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
                : simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            // Fallback transform — used immediately so the user always
            // sees a board, then refined by `PlacementController` once
            // ARKit locates a real table (Vision Pro device only). On
            // the simulator the fallback IS the final position.
            let fallback = Transform(
                scale: .one,
                rotation: baseRotation,
                translation: SIMD3<Float>(
                    0,
                    SceneMetrics.defaultTableHeight,
                    SceneMetrics.defaultTableDepth
                )
            )
            content.add(renderer.rootEntity)

            // If the user has enabled the virtual environment, load it,
            // apply the seated-POV transform, place the chessboard on
            // top of the in-env table, and add the cinematic lighting
            // + dust-mote particles. ARKit-based plane detection is
            // skipped in this mode (real-world surfaces aren't
            // relevant when we're showing a synthetic room).
            //
            // If env loading fails for any reason — corrupt USDZ,
            // missing AntiqueTable named entity, etc. — we silently
            // fall through to the AR placement path so the user
            // always gets a working board.
            var didMountVirtualEnv = false
            if appModel.selectedEnvironment.isVirtual {
                if let mount = await EnvironmentLoader.mount(
                    appModel.selectedEnvironment,
                    into: content
                ) {
                    var t = fallback
                    t.translation = mount.boardPosition
                    renderer.rootEntity.transform = t
                    didMountVirtualEnv = true
                }
            }

            // Hand the renderer's root to the placement controller, which
            // seats it at `fallback` immediately and then nudges it onto
            // a detected horizontal surface (table) within ~3 s. Skipped
            // in virtual-environment mode — the env's table IS the
            // surface we placed on.
            if !didMountVirtualEnv {
                let placement = PlacementController(fallback: fallback)
                self.placementController = placement
                placement.attach(boardEntity: renderer.rootEntity)
            }

            // Placement helper: small floating tooltip above the board
            // that surfaces "Looking for a flat surface…" / "Drag the
            // board's edge to reposition" / etc. Driven entirely by
            // `placementController.helperMessage`; the SwiftUI body in
            // the attachment closure shows / hides itself.
            if let helper = attachments.entity(for: "placement-helper") {
                helper.position = SIMD3<Float>(0, 0.45, 0)
                renderer.rootEntity.addChild(helper)
            }

            // Anchor the floating HUD to the right of the board, slightly
            // above the table surface, tilted up so it faces the user.
            //
            // When the root is rotated for Black, the HUD's local +x
            // would land on the user's *left* in world space and the
            // text would face away. Negate the local x and pre-multiply
            // an extra π Y rotation so the world-space pose ends up
            // identical to the White case — HUD on the user's right,
            // text reading correctly toward them.
            let hudLocalX = SceneMetrics.boardOuterSide / 2 + 0.10
            let baseTilt = simd_quatf(
                angle: -.pi / 6,         // tilt back ~30° toward the user
                axis: SIMD3<Float>(1, 0, 0)
            )
            if let hud = attachments.entity(for: "match-hud") {
                if needsBlackPerspective {
                    hud.position = SIMD3<Float>(-hudLocalX, 0.18, 0)
                    hud.transform.rotation = simd_quatf(
                        angle: .pi, axis: SIMD3<Float>(0, 1, 0)
                    ) * baseTilt
                } else {
                    hud.position = SIMD3<Float>(hudLocalX, 0.18, 0)
                    hud.transform.rotation = baseTilt
                }
                renderer.rootEntity.addChild(hud)
            }
            // Companion moves panel — sits on the OPPOSITE side of
            // the board from the action HUD so the chess set is
            // centered between the two surfaces. Slightly raised
            // (+12 cm Y, vs the HUD's 18 cm) so it floats clearly
            // separate even if the user turns their head and both
            // panels enter the same field of view.
            if let panel = attachments.entity(for: "moves-panel") {
                if needsBlackPerspective {
                    panel.position = SIMD3<Float>(hudLocalX, 0.30, 0)
                    panel.transform.rotation = simd_quatf(
                        angle: .pi, axis: SIMD3<Float>(0, 1, 0)
                    ) * baseTilt
                } else {
                    panel.position = SIMD3<Float>(-hudLocalX, 0.30, 0)
                    panel.transform.rotation = baseTilt
                }
                renderer.rootEntity.addChild(panel)
            }

            // Floating eval bar (review only). Sits between the moves
            // panel and the board's near edge, slightly forward so it
            // doesn't fight the panel surface for the same Z. Empty
            // attachment for non-review sessions — the SwiftUI body
            // bails to EmptyView so we don't pay the layout cost.
            if let evalBar = attachments.entity(for: "eval-bar") {
                let evalX = -hudLocalX + 0.10
                if needsBlackPerspective {
                    evalBar.position = SIMD3<Float>(-evalX, 0.18, 0.06)
                    evalBar.transform.rotation = simd_quatf(
                        angle: .pi, axis: SIMD3<Float>(0, 1, 0)
                    ) * baseTilt
                } else {
                    evalBar.position = SIMD3<Float>(evalX, 0.18, 0.06)
                    evalBar.transform.rotation = baseTilt
                }
                renderer.rootEntity.addChild(evalBar)
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
            case .puzzle:
                // PuzzleSession is ready as soon as it's created — no
                // engine to start. The board's already at the puzzle's
                // initial FEN via match.startPosition above.
                break
            case .review(let review):
                // Review is HUD-driven; analysis kicks off when the
                // HUD attachment appears. Wire the renderer to the
                // session's per-ply highlight callback so the from/to
                // squares of the displayed move are tinted by the
                // move's classification.
                review.reviewHighlightHandler = { [weak renderer] from, to, quality in
                    renderer?.setReviewHighlight(from: from, to: to, quality: quality)
                }
                review.bestMoveArrowHandler = { [weak renderer] from, to in
                    if let from, let to {
                        renderer?.showBestMoveArrow(from: from, to: to)
                    } else {
                        renderer?.clearBestMoveArrow()
                    }
                }
                // Initial paint — covers the case where the user lands
                // on the immersive at currentPly == -1 (clears any
                // stale highlight) and ensures we don't have to wait
                // for the first navigation event.
                review.emitReviewHighlight()
            }
        } attachments: {
            Attachment(id: "match-hud") {
                // Matchmaking overlay wins precedence — when the user
                // taps "Find opponent", the immersive opens before any
                // session arrives. We render the matchmaking HUD until
                // the game session is built; then this branch becomes
                // false and the per-session HUD below takes over.
                if let mm = appModel.matchmaking {
                    MatchmakingHUDView(state: mm) {
                        // Cancel — tear down the seek + immersive.
                        appModel.matchmaking = nil
                        appModel.immersiveSpaceState = .inTransition
                        Task { @MainActor in
                            await dismissImmersiveSpace()
                        }
                    }
                } else if let session = appModel.activeSession {
                    switch session {
                    case .local(let coord):
                        LocalMatchHUDView(
                            coordinator: coord,
                            placement: placementController
                        )
                    case .online(let online):
                        OnlineMatchHUDView(
                            session: online,
                            placement: placementController
                        )
                    case .puzzle(let puzzle):
                        PuzzleHUDView(session: puzzle)
                    case .review(let review):
                        ReviewHUDView(session: review)
                    }
                }
            }
            Attachment(id: "placement-helper") {
                PlacementHelperOverlay(controller: placementController)
            }
            // Companion floating panel — shows on the opposite side of
            // the board from the main HUD. The view inside differs by
            // session flavour: local match → MovesPanelView, puzzle →
            // PuzzlePanelView (online + review have their own surfaces).
            Attachment(id: "moves-panel") {
                if let session = appModel.activeSession {
                    switch session {
                    case .local(let coord):
                        MovesPanelView(coordinator: coord)
                    case .puzzle(let puzzle):
                        PuzzlePanelView(session: puzzle)
                    case .review(let review):
                        ReviewMovesPanelView(session: review)
                    case .online:
                        EmptyView()
                    }
                }
            }
            // Eval bar — only meaningful for review; other sessions
            // render an empty body so the attachment exists but
            // contributes nothing.
            Attachment(id: "eval-bar") {
                if case .review(let review) = appModel.activeSession {
                    ReviewEvalBarView(session: review)
                } else {
                    EmptyView()
                }
            }
        }
        .gesture(combinedDrag)
        .onChange(of: appModel.pieceCustomization.current) { _, newValue in
            // Live re-skin: when the user moves a colour picker in the
            // lobby's "Pieces" sheet while the immersive scene is
            // open, push the new material + board palette into the
            // running renderer. No teardown — pieces stay where they
            // are, squares + frame just take on the new colours.
            renderer?.setPieceMaterial(newValue)
            renderer?.setBoardSurface(newValue)
        }
        .onAppear {
            // The env-toggle flow set `pendingReopen` so `onDisappear`
            // would skip session teardown. We're back — clear the flag.
            appModel.pendingReopen = false
        }
        .onDisappear {
            // Stop ARKit either way so the world-sensing indicator
            // goes off promptly.
            if let placement = placementController {
                Task { await placement.tearDown() }
            }
            placementController = nil
            // If this dismiss is part of the env-toggle (planned
            // re-open), keep the active session alive so the rebuilt
            // scene picks it up unchanged. Otherwise tear down.
            if !appModel.pendingReopen {
                if let session = appModel.activeSession,
                   case .online(let online) = session {
                    Task { await online.disconnect() }
                }
                appModel.activeSession = nil
            }
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
        case .local:               return settings.resolvedHumanSide()
        case .online(let online):  return online.humanColor
        case .puzzle(let puzzle):  return puzzle.humanSide
        case .review:              return .white   // review board orientation
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

    /// Adds the 32 pieces of `position` and registers them both with
    /// the renderer and with TabletopKit's `TableSetup`. Used at first
    /// scene build — pass `Position.standardStart` for a fresh game,
    /// or `session.match.currentPosition` to rebuild the scene at the
    /// in-progress board state (env switch mid-game).
    private static func populatePieces(
        into setup: inout TableSetup,
        renderer: ChessRenderer,
        from position: Position,
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
                    // Frame drag is gated on an explicit HUD mode so a
                    // stray pinch on the board's edge can't move it.
                    switch placementController?.dragMode {
                    case .move:   onBoardPlacementChanged(value)
                    case .rotate: onBoardRotationChanged(value)
                    case .none:   break
                    }
                }
            }
            .onEnded { value in
                if value.entity.components[ChessPieceComponent.self] != nil {
                    onPieceDragEnded(value)
                } else if value.entity.name == BoardSurface.frameName {
                    switch placementController?.dragMode {
                    case .move:   onBoardPlacementEnded(value)
                    case .rotate: onBoardRotationEnded()
                    case .none:   break
                    }
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
        let liftedY = SceneMetrics.boardSurfaceY + ChessRenderer.liftHeight
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

    // MARK: - Board rotation drag

    /// Single-hand drag while the HUD's Rotate toggle is armed: the
    /// vector from the board's centre to the pinch point at gesture
    /// start defines a reference angle in the XZ plane; the same vector
    /// at every update yields a current angle. The delta is applied as
    /// a yaw (Y-axis) rotation on top of the rotation captured at
    /// gesture start. The sign is negated because RealityKit's +Y
    /// rotation is counterclockwise viewed from above, while a drag
    /// from +X toward +Z (toward the user) reads as a clockwise sweep.
    ///
    /// A small minimum radius guards against numerically wild swings
    /// when the user pinches very near the board centre (where small
    /// translations span huge angular changes).
    private func onBoardRotationChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let root = sceneRoot(containing: value.entity) else { return }
        let startScene = value.convert(value.startLocation3D, from: .local, to: .scene)
        let nowScene = value.convert(value.location3D, from: .local, to: .scene)
        let center = root.position(relativeTo: nil)

        let startVec = SIMD2<Float>(
            Float(startScene.x) - center.x,
            Float(startScene.z) - center.z
        )
        let nowVec = SIMD2<Float>(
            Float(nowScene.x) - center.x,
            Float(nowScene.z) - center.z
        )
        let minRadius: Float = 0.05
        guard simd_length(startVec) > minRadius,
              simd_length(nowVec)   > minRadius else { return }

        let startAngle = atan2(startVec.y, startVec.x)
        let nowAngle   = atan2(nowVec.y,   nowVec.x)
        let delta = nowAngle - startAngle

        if boardRotationOrigin == nil {
            boardRotationOrigin = root.transform.rotation
        }
        guard let origin = boardRotationOrigin else { return }

        let yaw = simd_quatf(angle: -delta, axis: SIMD3<Float>(0, 1, 0))
        root.transform.rotation = yaw * origin
    }

    private func onBoardRotationEnded() {
        boardRotationOrigin = nil
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
