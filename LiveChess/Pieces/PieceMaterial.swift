import Foundation
import SwiftUI
import UIKit

/// User-controlled appearance for the chess pieces AND the board.
/// Stored as a single value, persisted to `UserDefaults`, and consumed
/// by the renderer at piece-loading time + applied live via
/// `ChessRenderer.setPieceMaterial(_:)` / `setBoardColors(...)`.
///
/// The model has two halves:
///   * **Pieces** — `preset` selects the material family (plastic,
///     metal, wood, marble, glass, …); `whiteColor` / `blackColor`
///     provide a per-side base tint that either *is* the visible
///     colour (pure-PBR presets) or *multiplies* the texture
///     (texture-backed presets).
///   * **Board** — `lightSquareColor`, `darkSquareColor`, `frameColor`
///     are independent of the piece preset. The board always uses
///     the same matte-wood PBR baseline; the user picks colours to
///     suit their pieces.
///
/// `Equatable + Codable + Sendable` so the customisation view diffs
/// trivially, the store persists with JSONEncoder, and we can pass
/// values across actor boundaries safely.
struct PieceMaterial: Equatable, Sendable, Codable {

    var preset: Preset
    var whiteColor: PieceColor
    var blackColor: PieceColor
    var lightSquareColor: PieceColor
    var darkSquareColor: PieceColor
    var frameColor: PieceColor
    var squareMaterial: BoardMaterial
    var frameMaterial: BoardMaterial

    /// Per-slot wood-type pick. Only consulted when the slot's
    /// material is `.wood` (pieces with `preset == .wood`, or board
    /// squares / frame with `BoardMaterial.wood`). Defaults split
    /// classic chess set tones — pale oak for the white side / light
    /// squares, dark ebony for the black side / dark squares, and
    /// ebony for the frame so it reads as a darker rim by default.
    var whitePieceWood: WoodType
    var blackPieceWood: WoodType
    var lightSquareWood: WoodType
    var darkSquareWood: WoodType
    var frameWood: WoodType

    init(
        preset: Preset,
        whiteColor: PieceColor,
        blackColor: PieceColor,
        lightSquareColor: PieceColor = Self.defaultLightSquareColor,
        darkSquareColor: PieceColor = Self.defaultDarkSquareColor,
        frameColor: PieceColor = Self.defaultFrameColor,
        squareMaterial: BoardMaterial = .matte,
        frameMaterial: BoardMaterial = .matte,
        whitePieceWood: WoodType = .oak,
        blackPieceWood: WoodType = .ebony,
        lightSquareWood: WoodType = .oak,
        darkSquareWood: WoodType = .ebony,
        frameWood: WoodType = .ebony
    ) {
        self.preset = preset
        self.whiteColor = whiteColor
        self.blackColor = blackColor
        self.lightSquareColor = lightSquareColor
        self.darkSquareColor = darkSquareColor
        self.frameColor = frameColor
        self.squareMaterial = squareMaterial
        self.frameMaterial = frameMaterial
        self.whitePieceWood = whitePieceWood
        self.blackPieceWood = blackPieceWood
        self.lightSquareWood = lightSquareWood
        self.darkSquareWood = darkSquareWood
        self.frameWood = frameWood
    }

    // MARK: - Board defaults
    //
    // Match the legacy `ChessMaterials` board palette so existing
    // users see no visual change after this update lands.

    static let defaultLightSquareColor: PieceColor = .init(0.90, 0.82, 0.66)
    static let defaultDarkSquareColor:  PieceColor = .init(0.36, 0.23, 0.16)
    static let defaultFrameColor:       PieceColor = .init(0.20, 0.12, 0.07)

    // MARK: - Codable (custom for backwards compatibility)
    //
    // Earlier builds persisted only `preset / whiteColor / blackColor`
    // (and possibly a now-removed `.classic` preset). Decode each key
    // with a fallback so an old payload restores cleanly into the new
    // shape — board colours fill in with defaults, classic falls back
    // to plasticGlossy.

    private enum CodingKeys: String, CodingKey {
        case preset, whiteColor, blackColor
        case lightSquareColor, darkSquareColor, frameColor
        case squareMaterial, frameMaterial
        case whitePieceWood, blackPieceWood
        case lightSquareWood, darkSquareWood, frameWood
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.preset           = (try? c.decode(Preset.self,        forKey: .preset))           ?? .plasticGlossy
        self.whiteColor       = (try? c.decode(PieceColor.self,    forKey: .whiteColor))       ?? .init(0.96, 0.96, 0.94)
        self.blackColor       = (try? c.decode(PieceColor.self,    forKey: .blackColor))       ?? .init(0.10, 0.10, 0.12)
        self.lightSquareColor = (try? c.decode(PieceColor.self,    forKey: .lightSquareColor)) ?? Self.defaultLightSquareColor
        self.darkSquareColor  = (try? c.decode(PieceColor.self,    forKey: .darkSquareColor))  ?? Self.defaultDarkSquareColor
        self.frameColor       = (try? c.decode(PieceColor.self,    forKey: .frameColor))       ?? Self.defaultFrameColor
        self.squareMaterial   = (try? c.decode(BoardMaterial.self, forKey: .squareMaterial))   ?? .matte
        self.frameMaterial    = (try? c.decode(BoardMaterial.self, forKey: .frameMaterial))    ?? .matte
        self.whitePieceWood   = (try? c.decode(WoodType.self,      forKey: .whitePieceWood))   ?? .oak
        self.blackPieceWood   = (try? c.decode(WoodType.self,      forKey: .blackPieceWood))   ?? .ebony
        self.lightSquareWood  = (try? c.decode(WoodType.self,      forKey: .lightSquareWood))  ?? .oak
        self.darkSquareWood   = (try? c.decode(WoodType.self,      forKey: .darkSquareWood))   ?? .ebony
        self.frameWood        = (try? c.decode(WoodType.self,      forKey: .frameWood))        ?? .ebony
    }

    /// Material families exposed in the customisation UI. Each preset
    /// has its own metallic/roughness/clearcoat baseline; user-picked
    /// colour layers on top via `whiteColor` / `blackColor`.
    ///
    /// Texture-backed presets (`.wood`, `.marble`) sample CC0 PBR maps
    /// (col + normal + roughness) bundled under `Resources/Textures/`.
    /// Pure-PBR presets ignore textures and drive the look from
    /// baseColor + the metallic/roughness curve.
    enum Preset: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
        case plasticMatte
        case plasticGlossy
        case lacquered
        case polishedMetal
        case brushedMetal
        case ceramic
        case pearl
        case glass
        case wood
        case marble

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plasticMatte:   return "Matte Plastic"
            case .plasticGlossy:  return "Glossy Plastic"
            case .lacquered:      return "Lacquered"
            case .polishedMetal:  return "Polished Metal"
            case .brushedMetal:   return "Brushed Metal"
            case .ceramic:        return "Ceramic"
            case .pearl:          return "Pearl"
            case .glass:          return "Glass"
            case .wood:           return "Wood"
            case .marble:         return "Marble"
            }
        }

        /// Sensible default colour pair for each preset. Used as the
        /// picker's initial value when the user switches presets and
        /// as a hardcoded fallback when no persisted value exists.
        var defaultPair: (white: PieceColor, black: PieceColor) {
            switch self {
            case .plasticMatte, .plasticGlossy, .lacquered:
                // Sober crisp pair — warm white + near-black charcoal.
                return (.init(0.96, 0.96, 0.94), .init(0.10, 0.10, 0.12))
            case .polishedMetal, .brushedMetal:
                // Brushed-steel + warm gunmetal so neither side
                // overpowers the other.
                return (.init(0.85, 0.85, 0.83), .init(0.30, 0.30, 0.32))
            case .ceramic:
                // Porcelain whites + obsidian blacks.
                return (.init(0.97, 0.96, 0.93), .init(0.09, 0.08, 0.10))
            case .pearl:
                // Mother-of-pearl baseline (pinkish white + dark teal
                // pearl). Sheen layer sells the look.
                return (.init(0.94, 0.90, 0.88), .init(0.18, 0.22, 0.26))
            case .glass:
                // Near-colourless tints — real glass is almost neutral;
                // a strong tint reads as coloured plastic instead.
                return (.init(0.92, 0.95, 0.96), .init(0.30, 0.32, 0.36))
            case .wood:
                // Texture stays in its natural oak/walnut range; the
                // tints multiply, so a near-white tint preserves the
                // photographed colour. Users can repaint to "blue oak"
                // etc. by picking another colour.
                return (.init(0.92, 0.85, 0.74), .init(0.65, 0.42, 0.28))
            case .marble:
                // Same logic as wood — near-white tint shows the
                // photographed marble veining naturally.
                return (.init(0.95, 0.93, 0.90), .init(0.30, 0.28, 0.30))
            }
        }
    }

    /// Default applied on first launch (and whenever the user hits
    /// "Reset to default"). Glossy Plastic with sober warm-white +
    /// charcoal pair, plus the legacy maple/walnut/mahogany board
    /// palette — feels like a freshly-bought tournament set.
    static let `default`: PieceMaterial = {
        let pair = Preset.plasticGlossy.defaultPair
        return PieceMaterial(
            preset: .plasticGlossy,
            whiteColor: pair.white,
            blackColor: pair.black
        )
    }()
}

/// Wood species offered by the customisation UI for any slot whose
/// material is `.wood` (piece preset, square material, frame material).
/// Each variant points to a CC0 PBR texture set bundled under
/// `Resources/Textures/wood-<name>-{col,nor,rough}.jpg`. Adding a new
/// species means: download the textures, add a case here, and the UI
/// picks it up automatically (the chip selector is `CaseIterable`).
enum WoodType: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
    case oak       // Oak Veneer 01 — pale blonde, fine straight grain
    case walnut    // Fine Grained Wood — medium brown, tight grain
    case rosewood  // Rosewood Veneer 1 — rich reddish-brown, classic chess set wood
    case ebony     // Dark Wood — near-black, dramatic grain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oak:      return "Oak"
        case .walnut:   return "Walnut"
        case .rosewood: return "Rosewood"
        case .ebony:    return "Ebony"
        }
    }

    /// Filename prefix in the texture bundle. Combined with `-col` /
    /// `-nor` / `-rough` to form the actual texture lookup names used
    /// by `PieceMaterialFactory.textureCache`.
    var texturePrefix: String {
        switch self {
        case .oak:      return "wood-oak"
        case .walnut:   return "wood-walnut"
        case .rosewood: return "wood-rosewood"
        case .ebony:    return "wood-ebony"
        }
    }
}

/// Material families for the board's playing surface (squares + frame).
/// Deliberately a smaller palette than `PieceMaterial.Preset` — pearl /
/// glass / lacquered chess pieces work; pearl / glass / lacquered
/// boards do not. This enum exposes only what makes sense for a
/// flat-ish surface that a player will look at for an entire game.
///
/// Texture-backed variants (`.wood`, `.marble`) reuse the cached
/// CC0 PBR maps loaded by `PieceMaterialFactory.preloadTextures()`,
/// so adding the board surface costs no extra disk / memory.
enum BoardMaterial: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
    case matte
    case polished
    case wood
    case marble

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matte:    return "Matte"
        case .polished: return "Polished"
        case .wood:     return "Wood"
        case .marble:   return "Marble"
        }
    }
}

/// Codable RGB colour wrapper. SwiftUI `Color` and UIKit `UIColor` are
/// not directly Codable, and we want the persistence shape to be a
/// trivial JSON object so settings migrations (later) stay simple.
struct PieceColor: Equatable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        red = max(0, min(1, r))
        green = max(0, min(1, g))
        blue = max(0, min(1, b))
    }

    init(_ swiftUIColor: Color) {
        let resolved = swiftUIColor.resolve(in: .init())
        self.init(
            Double(resolved.red),
            Double(resolved.green),
            Double(resolved.blue)
        )
    }

    /// SwiftUI binding for the in-app `ColorPicker`.
    var swiftUI: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// Bridge into UIKit colour for `PhysicallyBasedMaterial.BaseColor`.
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}
