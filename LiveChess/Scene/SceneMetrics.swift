import Foundation

/// Real-world dimensions for the chess scene, in metres unless noted.
enum SceneMetrics {

    // MARK: - Board

    /// Side length of one square (40 mm).
    static let squareSize: Float = 0.040

    /// Side length of the playable 8×8 area.
    static let boardPlayableSide: Float = 8 * squareSize     // 320 mm

    /// Frame thickness around the playable area on each side.
    static let boardFrameWidth: Float = 0.020                // 20 mm

    /// Total side length including frame.
    static let boardOuterSide: Float = boardPlayableSide + 2 * boardFrameWidth

    /// Vertical thickness of the board.
    static let boardThickness: Float = 0.008                 // 8 mm

    /// Vertical thickness of one square (slightly proud of the frame).
    static let squareThickness: Float = boardThickness + 0.0005

    // MARK: - Pieces

    /// Diameter of all piece bases.
    static let pieceBaseDiameter: Float = 0.030              // 30 mm

    static func pieceHeight(for kind: PieceKind) -> Float {
        switch kind {
        case .pawn:   0.045   // 45 mm
        case .rook:   0.055
        case .knight: 0.060
        case .bishop: 0.065
        case .queen:  0.070
        case .king:   0.080   // 80 mm
        }
    }
}
