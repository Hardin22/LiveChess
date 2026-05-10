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

    /// Drives the initial chessboard placement on a detected horizontal
    /// table (Vision Pro device) and the "Move board" reposition flow.
    /// Fallbacks transparently to the hardcoded position on the
    /// simulator. Created in `make`, stashed here so the HUD's
    /// reposition button can reach it.
    @State private var placementController: PlacementController?

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
            if appModel.virtualEnvironmentEnabled {
                if let virtualBoardPos = await Self.mountVirtualEnvironment(
                    into: content
                ) {
                    var t = fallback
                    t.translation = virtualBoardPos
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
            if let hud = attachments.entity(for: "match-hud") {
                let hudLocalX = SceneMetrics.boardOuterSide / 2 + 0.10
                let baseTilt = simd_quatf(
                    angle: -.pi / 6,         // tilt back ~30° toward the user
                    axis: SIMD3<Float>(1, 0, 0)
                )
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
                        LocalMatchHUDView(
                            coordinator: coord,
                            placement: placementController
                        )
                    case .online(let online):
                        OnlineMatchHUDView(
                            session: online,
                            placement: placementController
                        )
                    }
                }
            }
            Attachment(id: "placement-helper") {
                PlacementHelperOverlay(controller: placementController)
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
        case .local: return settings.resolvedHumanSide()
        case .online(let online): return online.humanColor
        }
    }

    /// Loads `Resources/environment.usdz` (the colleague's Blender-
    /// authored dwarven chess hall with table + chairs + sconces +
    /// statues + arches), applies the seated-POV transform he wired,
    /// and adds the cinematic noir lighting + dust-mote particles he
    /// designed for it. Computes the world-space top of `AntiqueTable`
    /// and returns it (with a small upward lift) so the caller can
    /// seat the chessboard on it without z-fighting the table mesh.
    ///
    /// Returns `nil` on any failure (missing file, corrupt USDZ, no
    /// `AntiqueTable` child) so the caller can route through the AR
    /// placement fallback — the user always gets a playable board.
    private static func mountVirtualEnvironment(
        into content: any RealityViewContentProtocol
    ) async -> SIMD3<Float>? {
        let env: Entity
        do {
            env = try await Entity(named: "environment", in: .main)
        } catch {
            return nil
        }
        env.name = "VirtualEnvironment"

        // Seated-POV transform from the env author's reference scene.
        // Math (his comments): Blender black chair sits at (9, 0, 0.62)
        // facing -X toward the table. Rotating -π/2 around Y maps
        // chair-forward (-X) to user-forward (-Z), and translating by
        // (0, +0.3, -9.15) lands the chair eye at the user's natural
        // standing eye level near world origin. Net effect: the user
        // feels seated *in* the antique chair, looking across the
        // table at the opposite chair — the natural chess setup.
        env.transform.rotation = simd_quatf(
            angle: -.pi / 2,
            axis: SIMD3<Float>(0, 1, 0)
        )
        env.position = SIMD3<Float>(0, 0.3, -9.15)
        // Soften the candelabra lights baked into the USDZ before
        // adding the env to the scene — the author's tuning produces
        // hard bright rings on the floor (small attenuationRadius +
        // tight outer cone). Ours: lower intensity and widen
        // attenuation so the falloff fades into a gradient instead of
        // ending in a sharp circle.
        softenEmbeddedLights(in: env)
        content.add(env)

        // Locate the antique table and read its world-space top after
        // the env transform has been committed.
        guard let table = env.findEntity(named: "AntiqueTable") else {
            // Env mounted but we can't find the table — leave it
            // visible (the rest of the room is still nice) and bail
            // so the caller goes through the AR fallback for
            // positioning. Better than no board.
            return nil
        }
        let bounds = table.visualBounds(relativeTo: nil)
        let tableTopY = bounds.center.y + bounds.extents.y / 2
        // Lift the chessboard ~6 mm above the table mesh so its frame
        // doesn't z-fight the table surface (the board's frame extends
        // a few mm below its origin; flush placement causes the
        // muddy "blended" look the user reported).
        let lift: Float = 0.006
        let boardPosition = SIMD3<Float>(
            bounds.center.x,
            tableTopY + lift,
            bounds.center.z
        )

        // Cinematic noir lighting + dust motes, ported from the env
        // author's reference scene. Tuned to the geometry, so kept as
        // a unit. See `addEnvironmentLighting` and `addDustMotes`.
        addEnvironmentLighting(into: content)
        addDustMotes(into: content)

        return boardPosition
    }

    /// Walks the loaded environment's entity tree and softens any
    /// `PointLightComponent` / `SpotLightComponent` baked into the
    /// USDZ (the candelabras' point lights and any spot rigs the
    /// author included). Two adjustments:
    ///
    ///   * **intensity × 0.35** — the embedded lights overpower the
    ///     scene's authored key/rim because the candelabra mesh sits
    ///     close to the floor; cutting them way down lets the
    ///     authored noir lighting do its job.
    ///   * **attenuationRadius widened to ≥ 6 m** — the harsh bright
    ///     ring the user reported is the falloff hitting zero inside
    ///     a small radius; widening it spreads the gradient over
    ///     metres, so the boundary fades to nothing instead of
    ///     ending in a hard circle.
    ///   * **spot outer cone widened by 1.4×** — softens the edge
    ///     of any spot beam similarly.
    @MainActor
    private static func softenEmbeddedLights(in root: Entity) {
        var stack: [Entity] = [root]
        while let entity = stack.popLast() {
            if var p = entity.components[PointLightComponent.self] {
                p.intensity = p.intensity * 0.35
                p.attenuationRadius = max(p.attenuationRadius * 2.5, 6.0)
                entity.components.set(p)
            }
            if var s = entity.components[SpotLightComponent.self] {
                s.intensity = s.intensity * 0.35
                s.attenuationRadius = max(s.attenuationRadius * 2.5, 6.0)
                s.outerAngleInDegrees = min(s.outerAngleInDegrees * 1.4, 175)
                entity.components.set(s)
            }
            stack.append(contentsOf: entity.children)
        }
    }

    /// Four-light noir setup the env author tuned for this hall:
    ///   - KEY: tight warm spot directly above the table.
    ///   - RIM: warm molten-gold accent from far behind the room
    ///          (the Erebor signature glow), with a slow flicker.
    ///   - FILL: cool counter-light behind the user.
    ///   - TABLE FILL: small warm pool at table height for material
    ///                 readability on the pieces, also flickers.
    @MainActor
    private static func addEnvironmentLighting(
        into content: any RealityViewContentProtocol
    ) {
        // KEY — tight warm spotlight on the chess area. Stepped down
        // again (1.5M → 800K) after the user reported lingering
        // highlight clipping on glossy / metal presets — those PBR
        // curves multiply specular by intensity, so the dimmer key
        // still gives a pleasant warm pool but the highlights no
        // longer wash out the colour. Outer cone widened slightly
        // (65° → 75°) to soften the edge of the warm pool on the
        // table fabric.
        var key = SpotLightComponent(
            color: .init(red: 1.0, green: 0.78, blue: 0.45, alpha: 1.0),
            intensity: 800_000
        )
        key.attenuationRadius = 4.0
        key.innerAngleInDegrees = 30
        key.outerAngleInDegrees = 75
        let keyEntity = Entity()
        keyEntity.name = "KeyLight"
        keyEntity.components.set(key)
        keyEntity.look(
            at: SIMD3<Float>(0, 0.7, -1.0),
            from: SIMD3<Float>(0, 4.5, -1.0),
            relativeTo: nil
        )
        content.add(keyEntity)

        // RIM — warm molten-gold accent
        var rim = PointLightComponent(
            color: .init(red: 1.0, green: 0.45, blue: 0.12, alpha: 1.0),
            intensity: 1_200_000
        )
        rim.attenuationRadius = 18.0
        let rimEntity = Entity()
        rimEntity.name = "RimLight"
        rimEntity.components.set(rim)
        rimEntity.position = SIMD3<Float>(0, 4.0, -12.0)
        content.add(rimEntity)
        startLightFlicker(on: rimEntity, baseIntensity: 1_200_000, amplitude: 0.18, period: 2.7)

        // FILL — cool counter-light from entrance side
        var fill = PointLightComponent(
            color: .init(red: 0.45, green: 0.55, blue: 0.85, alpha: 1.0),
            intensity: 150_000
        )
        fill.attenuationRadius = 14.0
        let fillEntity = Entity()
        fillEntity.name = "FillLight"
        fillEntity.components.set(fill)
        fillEntity.position = SIMD3<Float>(0, 2.5, 5.0)
        content.add(fillEntity)

        // TABLE FILL — soft warm pool at table surface. Knocked down
        // again (40K → 22K) after the second round of feedback: the
        // glossy / metal presets were still picking up too much warm
        // spec on top of the dimmer KEY. Attenuation widened so the
        // remaining light spreads further before fading, keeping the
        // candle warmth without piling intensity on the pieces.
        var tableFill = PointLightComponent(
            color: .init(red: 1.0, green: 0.82, blue: 0.55, alpha: 1.0),
            intensity: 22_000
        )
        tableFill.attenuationRadius = 2.4
        let tableFillEntity = Entity()
        tableFillEntity.name = "TableFillLight"
        tableFillEntity.components.set(tableFill)
        tableFillEntity.position = SIMD3<Float>(0, 1.0, -1.0)
        content.add(tableFillEntity)
        startLightFlicker(on: tableFillEntity, baseIntensity: 22_000, amplitude: 0.10, period: 1.9)
    }

    /// Drives an organic-looking intensity flicker on a `PointLightComponent`
    /// using two superimposed sine waves at different frequencies.
    /// Cancelled implicitly when the entity is released (weak capture
    /// returns nil → loop exits).
    @MainActor
    private static func startLightFlicker(
        on entity: Entity,
        baseIntensity: Float,
        amplitude: Float,
        period: Double
    ) {
        Task { @MainActor [weak entity] in
            let start = Date()
            while !Task.isCancelled {
                guard let entity = entity else { return }
                let elapsed = Date().timeIntervalSince(start)
                let phase = (elapsed / period) * 2.0 * .pi
                let secondary = (elapsed / (period * 0.43)) * 2.0 * .pi
                let mix = (sin(phase) * 0.7 + sin(secondary) * 0.3)
                let modulator = Float(mix) * amplitude
                let newIntensity = baseIntensity * (1.0 + modulator)
                if var p = entity.components[PointLightComponent.self] {
                    p.intensity = newIntensity
                    entity.components.set(p)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Drifting dust motes — small tinted particles that float through
    /// the warm key-light beam, courtesy of the env author. Pure
    /// `ParticleEmitterComponent` so no asset dependency.
    @MainActor
    private static func addDustMotes(
        into content: any RealityViewContentProtocol
    ) {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = SIMD3<Float>(2.5, 2.0, 2.5)
        emitter.birthLocation = .volume
        emitter.birthDirection = .normal
        emitter.timing = .repeating(
            warmUp: 8.0,
            emit: .init(duration: .infinity),
            idle: nil
        )

        var main = emitter.mainEmitter
        main.birthRate = 35
        main.lifeSpan = 18
        main.lifeSpanVariation = 6
        main.size = 0.006
        main.sizeVariation = 0.003
        main.color = .constant(.single(
            .init(red: 1.0, green: 0.88, blue: 0.65, alpha: 0.8)
        ))
        main.opacityCurve = .gradualFadeInOut
        main.spreadingAngle = 0.5
        main.acceleration = SIMD3<Float>(0, -0.02, 0)
        main.angularSpeed = 0.2
        main.angularSpeedVariation = 0.1
        emitter.mainEmitter = main

        emitter.speed = 0.04
        emitter.speedVariation = 0.02

        let entity = Entity()
        entity.name = "DustMotes"
        entity.components.set(emitter)
        entity.position = SIMD3<Float>(0, 2.5, -1.0)
        content.add(entity)
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
