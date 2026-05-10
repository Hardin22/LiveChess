import Foundation
import RealityKit
import UIKit

/// Builds RealityKit `PhysicallyBasedMaterial` instances from a
/// `PieceMaterial` preset + per-side colour pick. The factory is
/// `@MainActor`-isolated because RealityKit material construction
/// touches `Material` value types that aren't `Sendable`-clean across
/// every property, and pre-loaded `TextureResource`s live in a static
/// cache keyed by texture name.
///
/// Texture-backed presets (`.wood`, `.marble`) read CC0 PBR maps from
/// the app bundle (`Resources/Textures/`). They're loaded once into
/// the static cache by `preloadTextures()` (called from
/// `PieceMeshFactory.preload`) so per-piece material construction is
/// synchronous and cheap. Pure-PBR presets ignore the cache entirely
/// — no I/O on construction.
@MainActor
enum PieceMaterialFactory {

    /// All texture resources the factory needs, keyed by base name
    /// (e.g. `"wood-light-col"`). Populated once by
    /// `preloadTextures()`. Missing entries cause the factory to fall
    /// back to a pure-PBR approximation of the requested preset, so a
    /// missing asset never crashes the renderer.
    private static var textureCache: [String: TextureResource] = [:]

    /// Loads every PBR texture used by any preset into the static
    /// cache. Idempotent — safe to call multiple times. Failed loads
    /// are silently skipped; the pure-PBR fallback handles the gap.
    static func preloadTextures() async {
        var names: [String] = ["marble-col", "marble-nor", "marble-rough"]
        for wood in WoodType.allCases {
            names.append("\(wood.texturePrefix)-col")
            names.append("\(wood.texturePrefix)-nor")
            names.append("\(wood.texturePrefix)-rough")
        }
        for name in names where textureCache[name] == nil {
            if let texture = try? await TextureResource(named: name) {
                textureCache[name] = texture
            }
        }
    }

    /// Returns a fully-configured `PhysicallyBasedMaterial` ready to
    /// assign to a `ModelComponent`. Every supported preset produces
    /// a non-nil result; the `Optional` return is preserved so the
    /// renderer can keep its "no override → keep baked materials"
    /// fallback wired up for any future preset that opts out.
    static func material(
        for config: PieceMaterial,
        side: Side
    ) -> PhysicallyBasedMaterial? {
        let tint = (side == .white ? config.whiteColor : config.blackColor).uiColor
        switch config.preset {
        case .plasticMatte:   return makePlasticMatte(tint: tint)
        case .plasticGlossy:  return makePlasticGlossy(tint: tint)
        case .lacquered:      return makeLacquered(tint: tint)
        case .polishedMetal:  return makePolishedMetal(tint: tint)
        case .brushedMetal:   return makeBrushedMetal(tint: tint)
        case .ceramic:        return makeCeramic(tint: tint)
        case .pearl:          return makePearl(tint: tint)
        case .glass:          return makeGlass(tint: tint)
        case .wood:           return makeWood(
            tint: tint,
            wood: side == .white ? config.whitePieceWood : config.blackPieceWood
        )
        case .marble:         return makeMarble(tint: tint)
        }
    }

    // MARK: - Pure-PBR presets

    private static func makePlasticMatte(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 0)
        m.roughness = 0.78
        return m
    }

    private static func makePlasticGlossy(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 0)
        m.roughness = 0.28
        m.clearcoat = .init(floatLiteral: 0.35)
        m.clearcoatRoughness = .init(floatLiteral: 0.20)
        return m
    }

    /// Glossy paint over a darker substrate — strong clearcoat
    /// separates a rich highlight from the underlying tint.
    private static func makeLacquered(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 0)
        m.roughness = 0.45
        m.clearcoat = .init(floatLiteral: 0.85)
        m.clearcoatRoughness = .init(floatLiteral: 0.08)
        return m
    }

    private static func makePolishedMetal(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 1)
        m.roughness = 0.12
        return m
    }

    private static func makeBrushedMetal(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 1)
        m.roughness = 0.42
        return m
    }

    /// Porcelain-style: zero metallic, low roughness, light clearcoat
    /// for the soft sheen ceramic gives off under candle-light.
    private static func makeCeramic(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 0)
        m.roughness = 0.18
        m.clearcoat = .init(floatLiteral: 0.25)
        m.clearcoatRoughness = .init(floatLiteral: 0.12)
        return m
    }

    /// Mother-of-pearl / nacre. Faked with a high clearcoat, very low
    /// roughness, and a slight metallic kick — sells the iridescent
    /// "shifting tint" look without needing a real anisotropic
    /// shader. Sheen would be ideal but isn't exposed on
    /// `PhysicallyBasedMaterial` in the visionOS RealityKit SDK we
    /// target.
    private static func makePearl(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 0.30)
        m.roughness = 0.18
        m.clearcoat = .init(floatLiteral: 0.70)
        m.clearcoatRoughness = .init(floatLiteral: 0.06)
        return m
    }

    /// Translucent glass — pushed as far as `PhysicallyBasedMaterial`
    /// allows on visionOS RealityKit. There is no exposed IOR /
    /// transmission knob (those live in ShaderGraph Materials, not
    /// here), so true Fresnel refraction isn't available. We fake
    /// volumetric depth by:
    ///   * rendering both faces (`faceCulling = .none`) so light
    ///     bouncing off the back of the piece is visible through the
    ///     front — a poor man's refraction,
    ///   * keeping baseColor near-white (tint shows subtly, like a
    ///     stained-glass tonal wash, not coloured plastic),
    ///   * pushing specular to the cap and roughness to ~0 so the
    ///     surface mirror-reflects the room with crisp highlights,
    ///   * a low blend opacity so the lighting environment shows
    ///     through clearly.
    /// Result: on a small chess piece under the noir hall lighting
    /// this reads as glass at a glance. For full-room realism you'd
    /// need a custom ShaderGraph material with thin-film + IOR.
    private static func makeGlass(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.metallic = .init(floatLiteral: 0)
        m.roughness = .init(floatLiteral: 0.0)
        m.specular = .init(floatLiteral: 1.0)
        m.clearcoat = .init(floatLiteral: 1.0)
        m.clearcoatRoughness = .init(floatLiteral: 0.0)
        m.faceCulling = .none
        m.blending = .transparent(opacity: .init(floatLiteral: 0.30))
        return m
    }

    // MARK: - Texture-backed presets

    private static func makeWood(tint: UIColor, wood: WoodType) -> PhysicallyBasedMaterial {
        let prefix = wood.texturePrefix
        var m = PhysicallyBasedMaterial()
        if let col = textureCache["\(prefix)-col"] {
            m.baseColor = .init(tint: tint, texture: .init(col))
        } else {
            m.baseColor = .init(tint: tint)
        }
        if let nor = textureCache["\(prefix)-nor"] {
            m.normal = .init(texture: .init(nor))
        }
        if let rough = textureCache["\(prefix)-rough"] {
            m.roughness = .init(scale: 1.0, texture: .init(rough))
        } else {
            m.roughness = 0.55
        }
        m.metallic = .init(floatLiteral: 0)
        m.clearcoat = .init(floatLiteral: 0.05)
        return m
    }

    // MARK: - Board surface (squares + frame)

    /// Material for a single board square. Same texture maps as the
    /// piece presets (no extra disk cost), but tuned for a flat
    /// surface — slightly higher roughness so the squares don't
    /// mirror-reflect the candelabras and steal attention from the
    /// pieces.
    ///
    /// `isLight` selects which wood variant to use for `.wood`
    /// (light/dark pair, mirroring the piece treatment); ignored for
    /// the other materials, which use a single texture or none.
    static func boardSquareMaterial(
        for config: PieceMaterial,
        isLight: Bool
    ) -> PhysicallyBasedMaterial {
        let tint = (isLight ? config.lightSquareColor : config.darkSquareColor).uiColor
        switch config.squareMaterial {
        case .matte:    return makeBoardMatte(tint: tint)
        case .polished: return makeBoardPolished(tint: tint)
        case .wood:     return makeBoardWood(
            tint: tint,
            wood: isLight ? config.lightSquareWood : config.darkSquareWood
        )
        case .marble:   return makeBoardMarble(tint: tint)
        }
    }

    /// Material for the frame around the playable area. Single tint
    /// (no light/dark split). Wood variant honours the user's
    /// `frameWood` pick — which defaults to ebony so the frame reads
    /// as a darker rim against most piece + square palettes.
    static func boardFrameMaterial(
        for config: PieceMaterial
    ) -> PhysicallyBasedMaterial {
        let tint = config.frameColor.uiColor
        switch config.frameMaterial {
        case .matte:    return makeBoardMatte(tint: tint)
        case .polished: return makeBoardPolished(tint: tint)
        case .wood:     return makeBoardWood(tint: tint, wood: config.frameWood)
        case .marble:   return makeBoardMarble(tint: tint)
        }
    }

    private static func makeBoardMatte(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.roughness = 0.6
        m.metallic = .init(floatLiteral: 0)
        return m
    }

    private static func makeBoardPolished(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint)
        m.roughness = 0.30
        m.metallic = .init(floatLiteral: 0)
        m.clearcoat = .init(floatLiteral: 0.55)
        m.clearcoatRoughness = .init(floatLiteral: 0.18)
        return m
    }

    private static func makeBoardWood(tint: UIColor, wood: WoodType) -> PhysicallyBasedMaterial {
        let prefix = wood.texturePrefix
        var m = PhysicallyBasedMaterial()
        if let col = textureCache["\(prefix)-col"] {
            m.baseColor = .init(tint: tint, texture: .init(col))
        } else {
            m.baseColor = .init(tint: tint)
        }
        if let nor = textureCache["\(prefix)-nor"] {
            m.normal = .init(texture: .init(nor))
        }
        if let rough = textureCache["\(prefix)-rough"] {
            m.roughness = .init(scale: 1.0, texture: .init(rough))
        } else {
            m.roughness = 0.6
        }
        m.metallic = .init(floatLiteral: 0)
        // No clearcoat — board wood reads better as a deep matte
        // surface; the pieces should be the only specular focus.
        return m
    }

    private static func makeBoardMarble(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let col = textureCache["marble-col"] {
            m.baseColor = .init(tint: tint, texture: .init(col))
        } else {
            m.baseColor = .init(tint: tint)
        }
        if let nor = textureCache["marble-nor"] {
            m.normal = .init(texture: .init(nor))
        }
        if let rough = textureCache["marble-rough"] {
            m.roughness = .init(scale: 1.0, texture: .init(rough))
        } else {
            m.roughness = 0.25
        }
        m.metallic = .init(floatLiteral: 0)
        // Light clearcoat for the polished-stone gleam typical of a
        // real marble board — stronger than wood, weaker than
        // polished plastic so it doesn't glare.
        m.clearcoat = .init(floatLiteral: 0.30)
        m.clearcoatRoughness = .init(floatLiteral: 0.15)
        return m
    }

    private static func makeMarble(tint: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let col = textureCache["marble-col"] {
            m.baseColor = .init(tint: tint, texture: .init(col))
        } else {
            m.baseColor = .init(tint: tint)
        }
        if let nor = textureCache["marble-nor"] {
            m.normal = .init(texture: .init(nor))
        }
        if let rough = textureCache["marble-rough"] {
            m.roughness = .init(scale: 1.0, texture: .init(rough))
        } else {
            m.roughness = 0.18
        }
        m.metallic = .init(floatLiteral: 0)
        m.clearcoat = .init(floatLiteral: 0.40)
        m.clearcoatRoughness = .init(floatLiteral: 0.10)
        return m
    }
}
