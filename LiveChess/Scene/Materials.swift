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
}
