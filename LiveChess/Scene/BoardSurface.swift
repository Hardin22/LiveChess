import Foundation
import RealityKit
import UIKit

/// Builds the visible 8×8 chessboard surface as a single RealityKit entity
/// hierarchy. Sits flat in the X-Z plane with the centre at the world
/// origin of its parent. The board is purely visual: piece positioning
/// is driven from the Domain `Square` via `position(for:)`.
@MainActor
enum BoardSurface {

    /// Builds the board entity. The returned root has the frame as a child
    /// at `frameName`, which is the entity scene-hosts use as a drag/hit
    /// target for placement gestures.
    static let frameName = "BoardFrame"

    static func makeEntity() -> Entity {
        let root = Entity()
        root.name = "ChessBoard"

        let base = makeBase()
        root.addChild(base)

        let inset = makeInsetGroove()
        root.addChild(inset)

        let squares = makeSquares()
        root.addChild(squares)

        return root
    }

    // MARK: - Components

    /// Single solid slab covering the full outer board area. Acts as
    /// both the structural board and the visible frame: the slab's
    /// top is at `y = 0`, and the 64 thin square tiles sit flush
    /// just above it. The portion of the slab left visible around
    /// the 8×8 square area IS the frame — no separate rim entities,
    /// no corner seams, no plank fragmentation.
    ///
    /// Tagged with `frameName` (both wrapper and slab) so the existing
    /// reposition gesture's hit-test still resolves to the frame.
    /// Slightly rounded corners (6 mm) give a tournament-board feel
    /// instead of a hard-edged Lego brick.
    private static func makeBase() -> Entity {
        let group = Entity()
        group.name = frameName

        let outer = SceneMetrics.boardOuterSide
        let thickness = SceneMetrics.boardThickness

        let slab = ModelEntity(
            mesh: .generateBox(
                size: [outer, thickness, outer],
                cornerRadius: 0.0025
            ),
            materials: [ChessMaterials.boardFrame]
        )
        // Recess the slab top by `boardBaseRecess` below the visible
        // playing surface so the squares' tops (which sit at
        // boardSurfaceY) end up strictly z-above the slab top —
        // eliminates the coplanar-surfaces z-fight that used to
        // mix the frame texture into the square texture along the
        // perimeter cells.
        slab.position = [0, SceneMetrics.boardSurfaceY - SceneMetrics.boardBaseRecess - thickness / 2, 0]
        slab.name = frameName
        slab.components.set(InputTargetComponent())
        slab.components.set(HoverEffectComponent())
        slab.generateCollisionShapes(recursive: false)
        group.addChild(slab)

        return group
    }

    /// Thin contrasting groove around the playable area — a refined
    /// detail that delineates the frame from the squares without
    /// adding height. Built as four very thin strips just inside
    /// the playable boundary, ~0.5 mm proud of the base. Reads as an
    /// inscribed line on real boards. Painted with the same frame
    /// material so it follows the user's frame-colour pick (slightly
    /// darkened so it still looks like a groove, not a paint smear).
    private static func makeInsetGroove() -> Entity {
        let group = Entity()
        group.name = "BoardGroove"

        let playable = SceneMetrics.boardPlayableSide
        let strip: Float = 0.0015               // 1.5 mm wide
        let thickness: Float = 0.0006           // 0.6 mm proud of base top
        let outerEdge = playable / 2 + strip / 2
        let topY: Float = thickness / 2

        var grooveMaterial = PhysicallyBasedMaterial()
        grooveMaterial.baseColor = .init(tint: UIColor(white: 0.05, alpha: 1))
        grooveMaterial.roughness = 0.55
        grooveMaterial.metallic = .init(floatLiteral: 0)

        let length = playable + strip * 2
        // North + south strips
        for z in [Float(-outerEdge), Float(+outerEdge)] {
            let bar = ModelEntity(
                mesh: .generateBox(size: [length, thickness, strip], cornerRadius: 0.0003),
                materials: [grooveMaterial]
            )
            bar.position = [0, topY, z]
            bar.name = "BoardGrooveBar"
            group.addChild(bar)
        }
        // East + west strips (slightly shorter so they tuck under the N/S strips)
        for x in [Float(-outerEdge), Float(+outerEdge)] {
            let bar = ModelEntity(
                mesh: .generateBox(size: [strip, thickness, playable], cornerRadius: 0.0003),
                materials: [grooveMaterial]
            )
            bar.position = [x, topY, 0]
            bar.name = "BoardGrooveBar"
            group.addChild(bar)
        }
        return group
    }

    private static func makeSquares() -> Entity {
        let group = Entity()
        group.name = "BoardSquares"

        for rank in 0..<8 {
            for file in 0..<8 {
                // Standard chess colouring: a1 (file 0 + rank 0 = 0, even) is
                // a DARK square; h1 (sum 7, odd) is LIGHT. `isLight` flips on
                // odd sums.
                let isLight = !(file + rank).isMultiple(of: 2)
                let squareEntity = ModelEntity(
                    mesh: .generateBox(
                        size: [SceneMetrics.squareSize, SceneMetrics.squareThickness, SceneMetrics.squareSize],
                        cornerRadius: 0.0
                    ),
                    materials: [ChessMaterials.square(forIsLight: isLight)]
                )
                let pos = position(for: Square(file: file, rank: rank)!)
                // Inlay: tile top sits exactly at boardSurfaceY (= 0,
                // same plane as the base slab's top), tile bottom
                // sinks into the slab and is occluded by it. ZERO
                // visible step from frame to square.
                squareEntity.position = [
                    pos.x,
                    SceneMetrics.boardSurfaceY - SceneMetrics.squareThickness / 2,
                    pos.z
                ]
                squareEntity.name = "Square_\(file)_\(rank)"
                // Collision + InputTarget without HoverEffect: the
                // square blocks the gaze ray so it doesn't fall
                // through to the frame slab underneath (which would
                // otherwise glow on every hover above the playable
                // area). The drag handler ignores entities that are
                // neither pieces nor the frame, so hovering / pinch-
                // dragging an empty square just does nothing.
                squareEntity.components.set(InputTargetComponent())
                squareEntity.generateCollisionShapes(recursive: false)
                group.addChild(squareEntity)
            }
        }
        return group
    }

    // MARK: - World-coordinates helpers

    /// Position (relative to the board root) of the centre of a `Square`,
    /// at the surface plane (`y = 0`).
    ///
    /// Coordinate convention: with the board root at default rotation, the
    /// player viewing the scene from `-z` looking at `+z`-forward sees:
    ///
    /// - **rank 1** (white's home rank, `square.rank == 0`) **closest** to them
    ///   (largest `+z` in root-local space → least-negative world `z` once the
    ///   root is positioned in front of the camera at world `z = -0.55`),
    /// - **rank 8** (black's home) **farthest**,
    /// - **a-file** (`file == 0`) on their **left** (most-negative `x`),
    /// - **h-file** on their right.
    ///
    /// This matches a real chess set viewed by White. When the human plays
    /// Black we flip the whole root 180° around `y` (TODO: wire in
    /// `MatchSettings.humanColor`).
    nonisolated static func position(for square: Square) -> SIMD3<Float> {
        let size = SceneMetrics.squareSize
        let half = SceneMetrics.boardPlayableSide / 2
        let x = -half + size * (Float(square.file) + 0.5)
        // Note the sign flip on z: rank 0 (rank 1) is the LARGEST z (closest
        // to the viewer when the root sits in front of them at negative world
        // z), rank 7 (rank 8) is the smallest. Without this flip the user
        // ends up sitting on Black's side and perceives the central files as
        // mirrored (queen and king look swapped).
        let z = +half - size * (Float(square.rank) + 0.5)
        return [x, 0, z]
    }

    /// Inverse of `position(for:)`: given a point in the board's local frame,
    /// returns the square containing it (or `nil` if the point lies outside
    /// the playable 8×8 area). Used by the drop-detection on piece drags.
    nonisolated static func square(forBoardLocalPosition position: SIMD3<Float>) -> Square? {
        let half = SceneMetrics.boardPlayableSide / 2
        let size = SceneMetrics.squareSize
        // x = -half + size * (file + 0.5)  ⇒  file = (x + half) / size - 0.5
        // z =  half - size * (rank + 0.5)  ⇒  rank = (half - z) / size - 0.5
        let file = Int(((position.x + half) / size).rounded(.down))
        let rank = Int(((half - position.z) / size).rounded(.down))
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        return Square(file: file, rank: rank)
    }
}
