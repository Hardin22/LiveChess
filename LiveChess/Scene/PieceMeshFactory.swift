import Foundation
import RealityKit

/// Builds placeholder piece geometry from primitive RealityKit meshes.
///
/// Each piece is composed as a small hierarchy of `ModelEntity`s under one
/// invisible parent `Entity`. The parent's origin sits at the centre of the
/// piece's base on the board surface (y = 0). Heights stack along `+y`.
///
/// These shapes are intentionally simple: distinct silhouettes by height +
/// crown, swappable with USDZ models later by replacing this factory.
@MainActor
enum PieceMeshFactory {

    static func makeEntity(for piece: Piece) -> Entity {
        let root = Entity()
        let material = ChessMaterials.piece(for: piece.color)
        let baseRadius = SceneMetrics.pieceBaseDiameter / 2
        let baseHeight: Float = 0.012   // 12 mm

        // Common base: short cylinder for every piece kind.
        let base = ModelEntity(
            mesh: .generateCylinder(height: baseHeight, radius: baseRadius),
            materials: [material]
        )
        base.position = [0, baseHeight / 2, 0]
        root.addChild(base)

        // Stem: a slightly thinner column up to the head.
        let totalHeight = SceneMetrics.pieceHeight(for: piece.kind)
        let headHeight = headHeight(for: piece.kind)
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
            // Tilt the "head" forward to suggest a horse profile.
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
            // Cross on top: vertical bar + horizontal bar.
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

    private static func headHeight(for kind: PieceKind) -> Float {
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
