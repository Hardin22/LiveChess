import Foundation
import Observation
import RealityKit
import ARKit

/// Drives the chessboard's initial position when the immersive scene
/// opens and when the user requests a "Reposition" pass.
///
/// Behaviour:
///   * On `start()`, immediately seats the board at the caller-supplied
///     fallback transform so the user always sees a board within one
///     frame — never a blank scene.
///   * In parallel, asks `PlaneDetectionService` for horizontal planes.
///     Within a `searchTimeout` window, if a plausible table is found
///     the board is moved there with a brief animation. Otherwise it
///     stays at the fallback and the helper hint flips to "drag the
///     edge to reposition".
///   * `reposition()` re-enters the search window (used by the HUD
///     "Move board" button when the user wants to move to a different
///     room or surface).
///   * Manual drag (the existing `onBoardPlacementChanged` in
///     `ChessSceneView`) is left untouched. The controller writes to
///     the board entity only during `.searching` / `.repositioning`
///     and stops touching it on `.placed`, so dragging the frame
///     after auto-placement keeps working as before.
@MainActor
@Observable
final class PlacementController {

    /// Active mode for a single-hand drag on the board frame. The HUD
    /// surfaces this as two toggle buttons (Move | Rotate); both default
    /// to off (`dragMode == nil`) so a stray pinch on the frame can't
    /// move the board unintentionally. Tapping a button arms its mode;
    /// tapping the active button again disarms it.
    enum DragMode: String, CaseIterable, Sendable, Identifiable {
        case move
        case rotate
        var id: String { rawValue }
    }

    enum State: Sendable, Equatable {
        /// Immersive just opened; ARKit session being brought up.
        case starting
        /// Actively scanning for a horizontal table; helper hint
        /// visible. Auto-transitions to `.placed` on success or
        /// timeout.
        case searching
        /// Board is at its final position. Manual drag is allowed.
        case placed
        /// User tapped "Move board"; same UX as `.searching`.
        case repositioning
        /// ARKit isn't available (sim, denied, hardware fail).
        /// Board stays at the fallback position; manual drag is the
        /// only repositioning affordance.
        case unavailable
    }

    private(set) var state: State = .starting

    /// Whether a single-hand frame drag currently translates, rotates,
    /// or is ignored. `nil` is the safe default: the user has to opt
    /// in via the HUD before a stray pinch can move the board.
    var dragMode: DragMode? = nil

    /// Optional one-line message the scene's helper attachment shows
    /// floating above the board. `nil` hides the attachment.
    private(set) var helperMessage: String?

    /// How long to keep scanning before falling back. 3 s is enough
    /// for a phone-style room scan to surface a table the user is
    /// looking at; longer feels like a hang.
    var searchTimeout: Duration = .seconds(3)

    /// How long the post-placement "drag the edge to reposition" hint
    /// stays visible after timeout-fallback. Auto-dismisses so it
    /// doesn't pollute the scene during play.
    var hintDismissDelay: Duration = .seconds(4)

    private let service: PlaneDetectionService
    private weak var boardEntity: Entity?
    private let fallbackTransform: Transform

    init(
        fallback: Transform,
        service: PlaneDetectionService = PlaneDetectionService()
    ) {
        self.service = service
        self.fallbackTransform = fallback
    }

    /// Wires the controller to the board entity it should move during
    /// placement. Call once from the scene's `make` closure right after
    /// the renderer's root entity has been added to `content`.
    func attach(boardEntity: Entity) {
        self.boardEntity = boardEntity
        // Seat at the fallback position immediately so the user never
        // sees a missing/black board, then kick off ARKit in the
        // background.
        boardEntity.transform = fallbackTransform
        Task { await self.start() }
    }

    /// Boots ARKit, waits for a plausible table within `searchTimeout`,
    /// snaps the board there if found. Idempotent.
    func start() async {
        guard state == .starting else { return }

        state = .searching
        helperMessage = "Looking for a flat surface…"

        let auth = await service.start()
        switch auth {
        case .allowed:
            await searchForTable()
        case .denied, .unavailable:
            state = .unavailable
            helperMessage = nil
            // Show a short hint anyway so users on the simulator
            // (and anyone who declined the prompt) know they can
            // still position the board manually.
            await flashHint("Drag the board's edge to reposition", for: hintDismissDelay)
        }
    }

    /// Re-enters the search window. Triggered by the HUD "Move board"
    /// button. On `.unavailable` (sim / denied) just refreshes the
    /// drag hint — there's no ARKit to reset.
    func reposition() {
        guard state != .starting else { return }
        if case .unavailable = state {
            Task { await flashHint("Drag the board's edge to reposition", for: hintDismissDelay) }
            return
        }
        state = .repositioning
        helperMessage = "Looking for a flat surface…"
        Task { await searchForTable() }
    }

    /// Called from the immersive's onDisappear. Stops the ARKit
    /// session so the world-sensing indicator doesn't stay lit while
    /// the user is back in the lobby window.
    func tearDown() async {
        await service.stop()
    }

    // MARK: - Private

    /// Polls the detection service for up to `searchTimeout` for a
    /// plausible horizontal table. Snaps to the best one if found,
    /// otherwise transitions to `.placed` at the fallback position.
    private func searchForTable() async {
        let deadline = ContinuousClock.now.advanced(by: searchTimeout)
        while ContinuousClock.now < deadline {
            let planes = await service.planes
            if let pick = pickBestPlane(from: planes) {
                applyPlacement(from: pick, animated: true)
                helperMessage = nil
                state = .placed
                return
            }
            // 200 ms poll cadence — well below the user-perceptible
            // delay; ARKit emits anchor updates more frequently than
            // this in practice but we don't want a tight spin loop.
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Timeout — board stays at fallback (already placed in attach).
        state = .placed
        await flashHint("Drag the board's edge to reposition", for: hintDismissDelay)
    }

    /// Ranks horizontal planes by classification (tables and seats
    /// preferred) and area (bigger is better). Returns the top
    /// candidate or nil if nothing plausible was detected.
    private func pickBestPlane(from planes: [PlaneAnchor]) -> PlaneAnchor? {
        // Filter to horizontal planes that are either explicitly
        // classified as a table/seat OR big enough to plausibly hold
        // a chessboard (45 cm × 40 cm minimum — see
        // `PlaneAnchor.isPlausibleTable`).
        let candidates = planes.filter { plane in
            guard plane.alignment == .horizontal else { return false }
            switch plane.surfaceClassification {
            case .table, .seat:
                return true
            case .floor, .ceiling, .wall, .window, .door:
                return false
            default:
                return plane.isPlausibleTable
            }
        }
        // Prefer table-classified, then largest area.
        return candidates.max { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            return lhsScore < rhsScore
        }
    }

    /// Scoring: tables get a 1.0 bonus over generic horizontal
    /// surfaces, then we add area in m². A 1 m² floor patch beats a
    /// 0.3 m² coffee table in raw area, but the .table classification
    /// flips it back to favour the actual table.
    private func score(_ plane: PlaneAnchor) -> Float {
        var s = plane.approximateArea
        if plane.surfaceClassification == .table { s += 1.0 }
        if plane.surfaceClassification == .seat  { s += 0.5 }
        return s
    }

    /// Moves the board entity to the plane's world-space centre. The
    /// animation pulse helps the user notice the snap when ARKit finds
    /// the table after the initial fallback frame.
    private func applyPlacement(from plane: PlaneAnchor, animated: Bool) {
        guard let board = boardEntity else { return }

        // Position the board with its base flush on the plane's
        // surface. Plane anchors report the table-top y; we keep the
        // board's existing rotation (it's set up to face the user
        // already, plus the Black-side π rotation if applicable).
        var newTransform = board.transform
        newTransform.translation = plane.worldCentre

        if animated {
            board.move(
                to: newTransform,
                relativeTo: nil,
                duration: 0.6,
                timingFunction: .easeInOut
            )
        } else {
            board.transform = newTransform
        }
    }

    /// Sets `helperMessage`, waits, then clears it (unless something
    /// else replaced it in the meantime). Used for transient drag
    /// hints after fallback or repositioning failure.
    private func flashHint(_ message: String, for duration: Duration) async {
        helperMessage = message
        let snapshot = message
        try? await Task.sleep(for: duration)
        if helperMessage == snapshot {
            helperMessage = nil
        }
    }
}
