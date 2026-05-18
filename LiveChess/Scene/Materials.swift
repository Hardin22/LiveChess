import Foundation
import RealityKit
import SwiftUI

/// PBR materials shared across the chess scene. Loaded once and reused by
/// every entity to keep memory and texture-sampler usage low.
@MainActor
enum ChessMaterials {

    // MARK: - Pieces

    /// Warm ivory white-piece body.
    static let whitePiece: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.94, green: 0.91, blue: 0.83, alpha: 1.0))
        m.roughness = 0.5
        m.metallic = 0.0
        return m
    }()

    /// Deep matte black-piece body with a touch of metallic for sheen.
    static let blackPiece: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.10, green: 0.09, blue: 0.10, alpha: 1.0))
        m.roughness = 0.4
        m.metallic = 0.05
        return m
    }()

    static func piece(for color: Side) -> PhysicallyBasedMaterial {
        color == .white ? whitePiece : blackPiece
    }

    // MARK: - Board

    /// Cream/maple light squares.
    static let lightSquare: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.90, green: 0.82, blue: 0.66, alpha: 1.0))
        m.roughness = 0.6
        m.metallic = 0.0
        return m
    }()

    /// Walnut dark squares.
    static let darkSquare: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.36, green: 0.23, blue: 0.16, alpha: 1.0))
        m.roughness = 0.55
        m.metallic = 0.0
        return m
    }()

    /// Mahogany frame around the board.
    static let boardFrame: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.20, green: 0.12, blue: 0.07, alpha: 1.0))
        m.roughness = 0.5
        m.metallic = 0.0
        return m
    }()

    static func square(forIsLight isLight: Bool) -> PhysicallyBasedMaterial {
        isLight ? lightSquare : darkSquare
    }

    // MARK: - Legal-move markers

    /// Resting style for a legal-destination dot — soft white, ~35% opaque.
    static func legalMoveMarkerMaterial() -> UnlitMaterial {
        var m = UnlitMaterial()
        m.color = .init(tint: UIColor(white: 1.0, alpha: 1.0))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        return m
    }

    /// Highlighted style for the dot under the dragged piece — warm gold,
    /// brighter, used while the user is hovering a particular destination.
    static func activeMoveMarkerMaterial() -> UnlitMaterial {
        var m = UnlitMaterial()
        m.color = .init(tint: UIColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 1.0))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        return m
    }

    /// Tinted overlay used during review to colour the source +
    /// destination squares of the move at the current ply by its
    /// classification. Colours match the HUD's `qualityColor` palette
    /// so the board, panel, and HUD stay consistent.
    static func reviewHighlightMaterial(for quality: MoveQuality) -> UnlitMaterial {
        var m = UnlitMaterial()
        m.color = .init(tint: tint(for: quality))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        return m
    }

    private static func tint(for quality: MoveQuality) -> UIColor {
        switch quality {
        case .brilliant:        return UIColor(red: 0.10, green: 0.85, blue: 1.00, alpha: 1)
        case .best, .great:     return UIColor(red: 0.25, green: 0.85, blue: 0.55, alpha: 1)
        case .book:             return UIColor(red: 0.40, green: 0.65, blue: 1.00, alpha: 1)
        case .excellent, .good: return UIColor(red: 0.45, green: 0.95, blue: 0.65, alpha: 1)
        case .inaccuracy:       return UIColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 1)
        case .missedWin:        return UIColor(red: 0.65, green: 0.40, blue: 1.00, alpha: 1)
        case .mistake:          return UIColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1)
        case .blunder:          return UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1)
        }
    }
}
