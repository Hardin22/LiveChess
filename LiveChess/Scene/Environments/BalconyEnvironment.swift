import Foundation
import RealityKit
import SwiftUI

/// Loads `Resources/balcony.usdz` (an outdoor stone balcony with
/// railings, fir trees, plant pots, and a centre table+chair set) and
/// applies daylight lighting tuned for the open setting.
///
/// The balcony's table object is `ChairTable_Root/node_0` in the USDZ.
/// We look up `node_0` (USD names get sanitized from Blender on
/// export) and seat the board on top of it.
@MainActor
enum BalconyEnvironment: EnvironmentScene {

    /// The Blender table object (after the joins / decimation in our
    /// optimizer) lives under `ChairTable_Root` and is the only mesh
    /// in that subtree, so a recursive name lookup hits it.
    private static let tableEntityName = "node_0"

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

        // The balcony was authored with the central chair facing -X,
        // same orientation convention as the dwarven hall. Rotate -π/2
        // around Y so the chair's forward maps to user-forward (-Z).
        // The scene origin in the .blend is at the centre of the floor;
        // pull the env back so the user feels seated at the table at
        // world origin.
        env.transform.rotation = simd_quatf(
            angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)
        )
        env.position = SIMD3<Float>(0, 0.0, -1.6)

        EnvironmentLighting.softenEmbeddedLights(in: env)
        content.add(env)

        // Try the table first; fall back to scene-bounds centre so the
        // user still gets a placeable board if the name lookup fails.
        let boardPos = EnvironmentLighting.boardPosition(
            onTableNamed: tableEntityName, in: env
        ) ?? SIMD3<Float>(0, 0.78, 0)

        addDaylightLighting(into: content)

        return EnvironmentMount(boardPosition: boardPos)
    }

    /// Three-light daylight setup for the open balcony:
    ///   - SUN: directional warm key from above-front (golden-hour sun).
    ///   - SKY FILL: cool diffuse fill from above to lift shadows.
    ///   - BOUNCE: weak warm ground-bounce so the bottom of pieces
    ///             doesn't read as black against the stone floor.
    private static func addDaylightLighting(
        into content: any RealityViewContentProtocol
    ) {
        // SUN — golden-hour directional key.
        let sun = DirectionalLightComponent(
            color: .init(red: 1.0, green: 0.92, blue: 0.78, alpha: 1.0),
            intensity: 6_000
        )
        let sunEntity = Entity()
        sunEntity.name = "BalconySun"
        sunEntity.components.set(sun)
        // DirectionalLight aims along -Z of its transform; tilt it down
        // and from camera-front so highlights hit the player's side of
        // the pieces.
        sunEntity.look(
            at: SIMD3<Float>(0, 0, 0),
            from: SIMD3<Float>(2.5, 5.0, 2.0),
            relativeTo: nil
        )
        content.add(sunEntity)

        // SKY FILL — cool diffuse top-down lift, wide attenuation.
        var sky = PointLightComponent(
            color: .init(red: 0.65, green: 0.78, blue: 1.0, alpha: 1.0),
            intensity: 250_000
        )
        sky.attenuationRadius = 12.0
        let skyEntity = Entity()
        skyEntity.name = "BalconySky"
        skyEntity.components.set(sky)
        skyEntity.position = SIMD3<Float>(0, 5.0, 0)
        content.add(skyEntity)

        // BOUNCE — warm ground-bounce so under-edges of pieces aren't
        // pure shadow on the dark stone floor.
        var bounce = PointLightComponent(
            color: .init(red: 1.0, green: 0.85, blue: 0.65, alpha: 1.0),
            intensity: 60_000
        )
        bounce.attenuationRadius = 3.0
        let bounceEntity = Entity()
        bounceEntity.name = "BalconyBounce"
        bounceEntity.components.set(bounce)
        bounceEntity.position = SIMD3<Float>(0, 0.2, 0)
        content.add(bounceEntity)
    }
}
