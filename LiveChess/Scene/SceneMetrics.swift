import Foundation

/// Real-world dimensions for the chess scene, in metres unless noted.
enum SceneMetrics {

    // MARK: - Board

    /// Side length of one square (60 mm — tournament-style board).
    static let squareSize: Float = 0.060

    /// Side length of the playable 8×8 area.
    static let boardPlayableSide: Float = 8 * squareSize     // 480 mm

    /// Frame thickness around the playable area on each side.
    static let boardFrameWidth: Float = 0.036                // 36 mm

    /// Total side length including frame.
    static let boardOuterSide: Float = boardPlayableSide + 2 * boardFrameWidth   // 552 mm

    /// Vertical thickness of the board's solid base slab. Acts as
    /// both the structural board AND the visible frame — the portion
    /// of the slab left uncovered around the 8×8 square area IS the
    /// frame (no separate rim entities, like a DGT smart board).
    static let boardThickness: Float = 0.014                 // 14 mm

    /// Vertical thickness of one square. Squares are inlaid into the
    /// base so their top sits exactly at `boardSurfaceY` — no visible
    /// step from frame to square. The thickness here only governs how
    /// deep the tile sinks into the slab; the bottom faces are
    /// occluded by the slab so they don't z-fight or read as a layer.
    static let squareThickness: Float = 0.0006               // 0.6 mm

    /// Y-plane of the visible playing surface in board-local
    /// coordinates. Square tiles' tops sit here, and pieces sit with
    /// their base here. Single source of truth so any future surface
    /// tweak only needs editing one constant.
    static let boardSurfaceY: Float = 0

    /// Tiny gap between the base slab's top and the squares' tops.
    /// Without this offset the two surfaces are coplanar and the
    /// depth buffer can't decide which to render → flickering /
    /// texture-mixing artefacts where the square material fights the
    /// frame material. 0.2 mm is below visual perception at any
    /// sensible viewing distance but enough to make the squares
    /// strictly z-above the slab.
    static let boardBaseRecess: Float = 0.0002

    // MARK: - Pieces

    /// Diameter of all piece bases (proportional to square: ~70%).
    static let pieceBaseDiameter: Float = 0.045              // 45 mm

    /// Per-kind heights — tournament pieces scaled to fit a 60 mm square.
    static func pieceHeight(for kind: PieceKind) -> Float {
        switch kind {
        case .pawn:   0.060   // 60 mm
        case .rook:   0.075
        case .knight: 0.085
        case .bishop: 0.090
        case .queen:  0.100
        case .king:   0.110   // 110 mm
        }
    }

    // MARK: - Scene placement

    /// Y-position (metres) of the board surface above the user's feet, used
    /// when no real-world anchor is detected (e.g. in the simulator). Roughly
    /// tabletop height for an adult.
    static let defaultTableHeight: Float = 0.78

    /// Z-position (metres) where the board sits in front of the user.
    /// Negative because the camera looks down `-z` in our setup.
    static let defaultTableDepth: Float = -0.55
}
