import Foundation
import ARKit

/// Wraps ARKit's `PlaneDetectionProvider` for the lifetime of one
/// immersive scene. Discovers horizontal surfaces in the user's room
/// (tables in particular) and exposes the current snapshot of detected
/// planes so the placement controller can pick the best candidate for
/// the chessboard.
///
/// Hard-fails gracefully on the visionOS Simulator (no real surfaces
/// to detect) and on devices where the user denies the
/// `NSWorldSensingUsageDescription` prompt — callers see
/// `Authorization.unavailable` and route through the manual-drag
/// fallback.
actor PlaneDetectionService {

    enum Authorization: Sendable, Equatable {
        /// Plane detection is up and running; `planes` will populate
        /// as ARKit finds horizontal surfaces.
        case allowed
        /// User denied the `NSWorldSensingUsageDescription` prompt.
        /// Settings → Privacy → Lichess to re-enable.
        case denied
        /// Device or platform doesn't support plane detection — the
        /// visionOS Simulator falls in this bucket, and so do real
        /// devices that fail to start the ARKit session for any
        /// other reason.
        case unavailable
    }

    /// Most recent snapshot of detected horizontal planes. Updated as
    /// `PlaneDetectionProvider` emits add/update/remove events.
    /// Reads from outside the actor must hop via `await`.
    private(set) var planes: [PlaneAnchor] = []

    private var session: ARKitSession?
    private var provider: PlaneDetectionProvider?
    private var pumpTask: Task<Void, Never>?

    init() {}

    /// Requests authorization, starts the ARKit session, and begins
    /// pumping plane updates into `planes`. Idempotent — calling more
    /// than once after a successful start returns `.allowed`
    /// immediately without re-running ARKit.
    func start() async -> Authorization {
        if session != nil { return .allowed }

        guard PlaneDetectionProvider.isSupported else {
            return .unavailable
        }

        let session = ARKitSession()
        let granted = await session.requestAuthorization(for: [.worldSensing])
        guard granted[.worldSensing] == .allowed else {
            return granted[.worldSensing] == .denied ? .denied : .unavailable
        }

        let provider = PlaneDetectionProvider(alignments: [.horizontal])
        do {
            try await session.run([provider])
        } catch {
            // Most common in practice: simulator hits this path because
            // the runtime supports the API but can't actually scan a
            // physical room. Treat as unavailable so the caller can
            // route through the fallback.
            return .unavailable
        }

        self.session = session
        self.provider = provider
        pumpTask = Task { [weak self] in
            await self?.pump(provider: provider)
        }
        return .allowed
    }

    /// Tears down the ARKit session and clears the plane cache. Called
    /// when the immersive scene is dismissed — keeps the world-sensing
    /// indicator (the small ARKit dot in the menu bar) from staying lit
    /// while the user is back in the lobby.
    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        session?.stop()
        session = nil
        provider = nil
        planes.removeAll()
    }

    deinit {
        pumpTask?.cancel()
        session?.stop()
    }

    // MARK: - Private

    /// Long-running pump: drains the provider's `anchorUpdates` async
    /// sequence and keeps `planes` in sync.
    private func pump(provider: PlaneDetectionProvider) async {
        for await update in provider.anchorUpdates {
            if Task.isCancelled { return }
            switch update.event {
            case .added, .updated:
                planes.removeAll { $0.id == update.anchor.id }
                planes.append(update.anchor)
            case .removed:
                planes.removeAll { $0.id == update.anchor.id }
            }
        }
    }
}

extension PlaneAnchor {
    /// Approximate area of the plane in m². Used by the placement
    /// controller to rank table candidates.
    var approximateArea: Float {
        let extent = geometry.extent
        return extent.width * extent.height
    }

    /// World-space position of the plane's centre point.
    var worldCentre: SIMD3<Float> {
        let t = originFromAnchorTransform * SIMD4<Float>(
            geometry.extent.anchorFromExtentTransform.columns.3.x,
            geometry.extent.anchorFromExtentTransform.columns.3.y,
            geometry.extent.anchorFromExtentTransform.columns.3.z,
            1
        )
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    /// True if the plane is large enough to plausibly be a table even
    /// when the classifier hasn't given it the `.table` label
    /// (e.g. unfurnished rooms or unusual tables that read as
    /// `.undetermined`). 0.18 m² ≈ 45 cm × 40 cm — comfortably bigger
    /// than the 480 mm playable side of the LiveChess board.
    var isPlausibleTable: Bool {
        approximateArea > 0.18
    }
}
