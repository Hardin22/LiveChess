import Foundation
import RealityKit

/// Builds piece RealityKit entities, preferring USDZ assets bundled in
/// `LiveChess/Resources/Pieces/` and falling back to procedural placeholder
/// shapes if a model is missing.
///
/// Naming convention for the bundled USDZ files (case-sensitive):
///   `<kind>_<color>.usdz` — e.g. `pawn_white.usdz`, `knight_black.usdz`.
///
/// USDZ models are auto-scaled along Y to match `SceneMetrics.pieceHeight(for:)`,
/// and re-anchored so the model's base sits at `y = 0`.
@MainActor
enum PieceMeshFactory {

    private static var templateCache: [String: Entity] = [:]
    private static var preloadComplete: Bool = false

    /// Loads all 12 piece USDZ models into the cache. Must complete before
    /// `makeEntity(for:)` is called for full-fidelity output; missing models
    /// silently fall back to procedural placeholders.
    static func preload() async {
        guard !preloadComplete else { return }
        for kind in PieceKind.allCases {
            for color in [Side.white, Side.black] {
                let name = filename(for: Piece(kind, color))
                if let entity = try? await Entity(named: name, in: .main) {
                    templateCache[name] = entity
                }
            }
        }
        preloadComplete = true
    }

    static func makeEntity(for piece: Piece) -> Entity {
        let name = filename(for: piece)
        if let template = templateCache[name] {
            return cloneAndNormalize(template, for: piece)
        }
        return makePlaceholderEntity(for: piece)
    }

    // MARK: - USDZ scaling

    /// Clones the template, uniformly scales so its measured Y-extent equals
    /// the target height for `piece.kind`, and re-centres it inside a wrapper
    /// `Entity` so that:
    ///
    /// - the model's geometric centre in X and Z lands at the wrapper origin
    ///   (regardless of where the USDZ author placed the model's pivot —
    ///   different Blender exports often have wildly different intrinsic
    ///   pivots, which was making major pieces drift off their squares),
    /// - the model's base sits on the wrapper's `y = 0` plane.
    ///
    /// Callers position the *wrapper* at the centre of the destination square;
    /// the visual centre of the piece then lines up exactly, every time.
    private static func cloneAndNormalize(_ template: Entity, for piece: Piece) -> Entity {
        let model = template.clone(recursive: true)
        let bounds = model.visualBounds(recursive: true, relativeTo: nil)

        let measuredHeight = bounds.extents.y
        let target = SceneMetrics.pieceHeight(for: piece.kind)
        let scale: Float = measuredHeight > 0 ? target / measuredHeight : 1.0
        model.scale = SIMD3<Float>(repeating: scale)

        // Counter-translate by the scaled bounds so the model's geometric
        // centre (X, Z) and base (min Y) end up at the wrapper origin and
        // y = 0 respectively. Without this, an off-centre USDZ pivot
        // shifts the rendered piece visibly off its square.
        model.position = SIMD3<Float>(
            -bounds.center.x * scale,
            -bounds.min.y    * scale,
            -bounds.center.z * scale
        )

        let wrapper = Entity()
        wrapper.addChild(model)
        return wrapper
    }

    private static func filename(for piece: Piece) -> String {
        let kindName: String
        switch piece.kind {
        case .pawn:   kindName = "pawn"
        case .knight: kindName = "knight"
        case .bishop: kindName = "bishop"
        case .rook:   kindName = "rook"
        case .queen:  kindName = "queen"
        case .king:   kindName = "king"
        }
        let colorName = piece.color == .white ? "white" : "black"
        return "\(kindName)_\(colorName)"
    }

    // MARK: - Procedural fallback (used until USDZ are loaded)

    private static func makePlaceholderEntity(for piece: Piece) -> Entity {
        let root = Entity()
        let material = ChessMaterials.piece(for: piece.color)
        let baseRadius = SceneMetrics.pieceBaseDiameter / 2
        let baseHeight: Float = 0.012

        let base = ModelEntity(
            mesh: .generateCylinder(height: baseHeight, radius: baseRadius),
            materials: [material]
        )
        base.position = [0, baseHeight / 2, 0]
        root.addChild(base)

        let totalHeight = SceneMetrics.pieceHeight(for: piece.kind)
        let headHeight = placeholderHeadHeight(for: piece.kind)
        let stemHeight = max(0, totalHeight - baseHeight - headHeight)
        if stemHeight > 0 {
            let stem = ModelEntity(
                mesh: .generateCylinder(height: stemHeight, radius: baseRadius * 0.55),
                materials: [material]
            )
            stem.position = [0, baseHeight + stemHeight / 2, 0]
            root.addChild(stem)
        }
        let topY = baseHeight + stemHeight

        switch piece.kind {
        case .pawn:
            let radius = baseRadius * 0.7
            let head = ModelEntity(
                mesh: .generateSphere(radius: radius),
                materials: [material]
            )
            head.position = [0, topY + radius, 0]
            root.addChild(head)

        case .rook:
            let crown = ModelEntity(
                mesh: .generateBox(
                    size: [baseRadius * 1.5, headHeight, baseRadius * 1.5],
                    cornerRadius: 0.001
                ),
                materials: [material]
            )
            crown.position = [0, topY + headHeight / 2, 0]
            root.addChild(crown)

        case .knight:
            let crown = ModelEntity(
                mesh: .generateBox(
                    size: [baseRadius * 0.9, headHeight, baseRadius * 1.6],
                    cornerRadius: 0.002
                ),
                materials: [material]
            )
            crown.transform.rotation = simd_quatf(angle: .pi / 6, axis: [1, 0, 0])
            crown.position = [0, topY + headHeight / 2, 0]
            root.addChild(crown)

        case .bishop:
            let cone = ModelEntity(
                mesh: .generateCone(height: headHeight, radius: baseRadius * 0.8),
                materials: [material]
            )
            cone.position = [0, topY + headHeight / 2, 0]
            root.addChild(cone)

        case .queen:
            let coneHeight = headHeight * 0.75
            let cone = ModelEntity(
                mesh: .generateCone(height: coneHeight, radius: baseRadius * 0.85),
                materials: [material]
            )
            cone.position = [0, topY + coneHeight / 2, 0]
            root.addChild(cone)
            let crownRadius = baseRadius * 0.45
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: crownRadius),
                materials: [material]
            )
            sphere.position = [0, topY + coneHeight + crownRadius, 0]
            root.addChild(sphere)

        case .king:
            let coneHeight = headHeight * 0.7
            let cone = ModelEntity(
                mesh: .generateCone(height: coneHeight, radius: baseRadius * 0.85),
                materials: [material]
            )
            cone.position = [0, topY + coneHeight / 2, 0]
            root.addChild(cone)
            let barThickness: Float = 0.004
            let barLength: Float = baseRadius * 0.8
            let vertical = ModelEntity(
                mesh: .generateBox(size: [barThickness, barLength, barThickness]),
                materials: [material]
            )
            vertical.position = [0, topY + coneHeight + barLength / 2, 0]
            root.addChild(vertical)
            let horizontal = ModelEntity(
                mesh: .generateBox(size: [barLength * 0.6, barThickness, barThickness]),
                materials: [material]
            )
            horizontal.position = [0, topY + coneHeight + barLength * 0.65, 0]
            root.addChild(horizontal)
        }

        return root
    }

    private static func placeholderHeadHeight(for kind: PieceKind) -> Float {
        switch kind {
        case .pawn:   0.022
        case .rook:   0.014
        case .knight: 0.020
        case .bishop: 0.024
        case .queen:  0.026
        case .king:   0.028
        }
    }
}
