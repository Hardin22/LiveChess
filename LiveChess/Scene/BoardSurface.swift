import Foundation
import RealityKit

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

        let frame = makeFrame()
        root.addChild(frame)

        let squares = makeSquares()
        root.addChild(squares)

        return root
    }

    // MARK: - Components

    private static func makeFrame() -> Entity {
        // Build the frame as four thin edge slabs surrounding the playable
        // 8×8 area, **not** as a single box underneath the squares. The
        // hollow shape means hit-tests on a square (which has no collision)
        // pass through to nothing, instead of falling through to the frame
        // below — so the user can hover/drag pieces without the frame
        // catching every interaction it shouldn't.
        let outer = SceneMetrics.boardOuterSide
        let playable = SceneMetrics.boardPlayableSide
        let edge = SceneMetrics.boardFrameWidth
        let thickness = SceneMetrics.boardThickness
        let edgeCenter = playable / 2 + edge / 2

        let group = Entity()
        group.name = frameName

        // North + south edges run along x and span the full outer width so
        // the corners overlap nicely with the side rails.
        for z in [Float(-edgeCenter), Float(+edgeCenter)] {
            let bar = makeFrameBar(
                size: [outer, thickness, edge],
                position: [0, -thickness / 2, z]
            )
            group.addChild(bar)
        }
        // East + west edges run along z and only span the playable depth so
        // they don't overlap with the N/S corners (avoids z-fight artefacts).
        for x in [Float(-edgeCenter), Float(+edgeCenter)] {
            let bar = makeFrameBar(
                size: [edge, thickness, playable],
                position: [x, -thickness / 2, 0]
            )
            group.addChild(bar)
        }
        return group
    }

    private static func makeFrameBar(
        size: SIMD3<Float>,
        position: SIMD3<Float>
    ) -> ModelEntity {
        let bar = ModelEntity(
            mesh: .generateBox(size: size, cornerRadius: 0.002),
            materials: [ChessMaterials.boardFrame]
        )
        bar.position = position
        bar.name = frameName
        bar.components.set(InputTargetComponent())
        bar.components.set(HoverEffectComponent())
        bar.generateCollisionShapes(recursive: false)
        return bar
    }

    private static func makeSquares() -> Entity {
        let group = Entity()
        group.name = "BoardSquares"

        for rank in 0..<8 {
            for file in 0..<8 {
                // Standard chess colouring: a1 (file 0 + rank 0 = 0, even) is
                // a DARK square; h1 (sum 7, odd) is LIGHT. So `isLight` flips
                // on **odd** sums, not even — the previous formula had this
                // backwards, which is why e1 was rendering light instead of dark.
                let isLight = !(file + rank).isMultiple(of: 2)
                let squareEntity = ModelEntity(
                    mesh: .generateBox(
                        size: [SceneMetrics.squareSize, SceneMetrics.squareThickness, SceneMetrics.squareSize],
                        cornerRadius: 0.0005
                    ),
                    materials: [ChessMaterials.square(forIsLight: isLight)]
                )
                let pos = position(for: Square(file: file, rank: rank)!)
                // Squares sit slightly above the frame top (y > 0) so seams stay clean.
                squareEntity.position = [pos.x, SceneMetrics.squareThickness / 2 - 0.0001, pos.z]
                squareEntity.name = "Square_\(file)_\(rank)"
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
