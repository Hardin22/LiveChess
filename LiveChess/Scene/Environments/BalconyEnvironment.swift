import Foundation
import RealityKit
import SwiftUI

/// Loads `Resources/balcony.usdz` (open-air balcony — glass railings,
/// chrome handrail, planters, a combined chair-and-table set authored
/// as `ChairTable_Root`, and an embedded sun + dome light).
///
/// The chair and table are fused into a single `ChairTable_Root` Xform
/// in the asset, so unlike the dwarven hall there is no isolated table
/// mesh to read a top-Y from. The board position is computed off the
/// anchored table-root centre with a fixed authored table-top height
/// (≈0.74 m), which matches the Blender source.
///
/// A textured inverted-normal sphere wraps the scene with the authored
/// `balcony_skybox.jpg` so the periphery reads as a warm sunset sky
/// instead of the visionOS passthrough void at oblique viewing angles.
@MainActor
enum BalconyEnvironment: EnvironmentScene {

    private static let tableEntityName = "ChairTable_Root"

    /// Authored table-top height for the combined ChairTable mesh.
    /// The .blend's mesh-Z histogram puts the dense table-surface
    /// cluster at Z = 0.73–0.77 m (chair seat is ~0.48 m, chair-back
    /// top is ~0.81 m). Park the board just above the table plane so
    /// it doesn't intersect with the table mesh.
    private static let tableTopY: Float = 0.79

    /// World-space offset to nudge the board from the chair+table+chair
    /// assembly center to the actual table-top center. Derived by
    /// filtering up-facing polygons at table-top Z (0.74–0.78 m) in
    /// the source .blend and area-weighting their centroid, so chair
    /// backs and tiny edge bevels don't bias the average. With the
    /// env's -π/2 Y rotation, the Blender Δ (+0.029 X, -0.047 Y) maps
    /// to world (+0.047 X, +0.029 Z) — pulls the board toward the
    /// viewer-side chair and to the user's right.
    private static let boardCenterOffset = SIMD3<Float>(0.047, 0, 0.029)

    static func mount(
        into content: any RealityViewContentProtocol
    ) async -> EnvironmentMount? {
        let env: Entity
        do {
            env = try await Entity(named: "balcony", in: .main)
        } catch {
            return nil
        }
        env.name = "VirtualEnvironment_Balcony"

        // Rotate the whole env -π/2 around Y (clockwise when viewed
        // from above). The .blend authors the balcony so the chair
        // faces world +Z; rotating -90° lands the chair facing -Z
        // (toward the user) so the seated-POV transform reads chair-
        // to-chair across the table instead of along it. anchorEnvByTable
        // below then refines X/Z so the table centres directly in
        // front of the user with the chair falling behind world origin.
        env.transform.rotation = simd_quatf(
            angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)
        )
        env.position = .zero

        EnvironmentLighting.softenEmbeddedLights(in: env)
        content.add(env)

        EnvironmentLighting.anchorEnvByTable(
            env, tableNamed: tableEntityName, frontDistance: 0.55
        )

        // ChairTable_Root's bounding box spans the chair back too, so
        // its top-Y is well above the table surface. Use the authored
        // table height instead and only borrow X/Z from the anchored
        // root for board placement.
        let boardPos: SIMD3<Float>
        if let table = env.findEntity(named: tableEntityName) {
            let b = table.visualBounds(relativeTo: nil)
            boardPos = SIMD3<Float>(
                b.center.x + boardCenterOffset.x,
                tableTopY + 0.006,
                b.center.z + boardCenterOffset.z
            )
        } else {
            boardPos = SIMD3<Float>(0, tableTopY + 0.006, -0.55)
        }

        await addSkydome(into: content)
        addGoldenHourLighting(into: content)

        return EnvironmentMount(boardPosition: boardPos)
    }

    /// Large inverted-normal sphere textured with `balcony_skybox.jpg`
    /// so the world beyond the railings reads as a warm sunset sky.
    /// Unlit so the skybox stays at full brightness regardless of the
    /// scene's lighting rig.
    private static func addSkydome(
        into content: any RealityViewContentProtocol
    ) async {
        let sphere = MeshResource.generateSphere(radius: 80)
        var unlit = UnlitMaterial()
        if let tex = try? await TextureResource(
            named: "balcony_skybox", in: .main
        ) {
            unlit.color = .init(tint: .white, texture: .init(tex))
        } else {
            unlit.color = .init(
                tint: .init(red: 0.95, green: 0.62, blue: 0.38, alpha: 1.0)
            )
        }
        let dome = ModelEntity(mesh: sphere, materials: [unlit])
        dome.name = "BalconySkydome"
        // Flip on X so the texture renders on the inside of the sphere.
        dome.scale = SIMD3<Float>(-1, 1, 1)
        dome.position = SIMD3<Float>(0, 1.4, 0)
        content.add(dome)
    }

    /// Golden-hour balcony lighting:
    ///   - SUN: warm directional-style spot from camera-right + above,
    ///     simulating low sun raking across the table.
    ///   - SKY FILL: cool zenith fill to keep the shadow side of pieces
    ///     readable rather than crushed-black.
    ///   - BOUNCE: warm low pool from the floor in front to mimic light
    ///     bouncing off the balcony's warm wood/stone deck.
    ///   - CANDLE: tight warm pool at table height with subtle flicker,
    ///     keying the candle prop that the env author placed by the chair.
    private static func addGoldenHourLighting(
        into content: any RealityViewContentProtocol
    ) {
        var sun = SpotLightComponent(
            color: .init(red: 1.0, green: 0.72, blue: 0.42, alpha: 1.0),
            intensity: 1_100_000
        )
        sun.attenuationRadius = 12.0
        sun.innerAngleInDegrees = 40
        sun.outerAngleInDegrees = 85
        let sunEntity = Entity()
        sunEntity.name = "BalconySun"
        sunEntity.components.set(sun)
        sunEntity.look(
            at: SIMD3<Float>(0, 0.7, -0.5),
            from: SIMD3<Float>(4.5, 3.8, 1.0),
            relativeTo: nil
        )
        content.add(sunEntity)

        var sky = PointLightComponent(
            color: .init(red: 0.55, green: 0.72, blue: 1.0, alpha: 1.0),
            intensity: 220_000
        )
        sky.attenuationRadius = 14.0
        let skyEntity = Entity()
        skyEntity.name = "BalconySkyFill"
        skyEntity.components.set(sky)
        skyEntity.position = SIMD3<Float>(0, 5.0, 0)
        content.add(skyEntity)

        var bounce = PointLightComponent(
            color: .init(red: 1.0, green: 0.78, blue: 0.55, alpha: 1.0),
            intensity: 80_000
        )
        bounce.attenuationRadius = 6.0
        let bounceEntity = Entity()
        bounceEntity.name = "BalconyBounce"
        bounceEntity.components.set(bounce)
        bounceEntity.position = SIMD3<Float>(0, 0.05, -1.2)
        content.add(bounceEntity)

        var candle = PointLightComponent(
            color: .init(red: 1.0, green: 0.65, blue: 0.30, alpha: 1.0),
            intensity: 28_000
        )
        candle.attenuationRadius = 2.2
        let candleEntity = Entity()
        candleEntity.name = "BalconyCandle"
        candleEntity.components.set(candle)
        candleEntity.position = SIMD3<Float>(0.35, 0.82, -0.45)
        content.add(candleEntity)
        EnvironmentLighting.startFlicker(
            on: candleEntity,
            baseIntensity: 28_000,
            amplitude: 0.22,
            period: 2.1
        )
    }
}
