import Foundation

/// Real-world dimensions for the chess scene, in metres unless noted.
enum SceneMetrics {

    // MARK: - Board

    /// Side length of one square (60 mm — tournament-style board).
    static let squareSize: Float = 0.060

    /// Side length of the playable 8×8 area.
    static let boardPlayableSide: Float = 8 * squareSize     // 480 mm

    /// Frame thickness around the playable area on each side.
    static let boardFrameWidth: Float = 0.030                // 30 mm

    /// Total side length including frame.
    static let boardOuterSide: Float = boardPlayableSide + 2 * boardFrameWidth   // 540 mm

    /// Vertical thickness of the board.
    static let boardThickness: Float = 0.012                 // 12 mm

    /// Vertical thickness of one square (slightly proud of the frame).
    static let squareThickness: Float = boardThickness + 0.0005

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
