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
    /// optimizer) lives under `ChairTable_Root`. The combined chair-
    /// table mesh is exported as `node_0`; a recursive name lookup
    /// hits it from anywhere in the env tree.
    private static let chairTableEntityName = "node_0"

    /// Where we'd like the chair+table cluster's centre to land in
    /// world space, relative to the user's feet (world origin).
    ///
    ///   * `y` left at the cluster's own centre — the env's floor is
    ///     already authored at Blender Z = 0 so it lands on the user's
    ///     real floor when env Y stays 0.
    ///   * `z = -0.55` — table centre ~55 cm in front of the user.
    ///     The cluster's long axis (2.26 m) lies along world Z after
    ///     the rotation below, so the FAR chair sits ~1.68 m forward
    ///     and the NEAR chair (the one the user "sits in") lands
    ///     ~0.58 m *behind* the user's heels — exactly where a chair
    ///     would be relative to a seated player.
    private static let targetClusterCenterXZ = SIMD2<Float>(0, -0.55)

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

        // Rotate the env so the chair+table cluster's wide axis
        // (2.26 m, runs through both seats and the table between
        // them in the .blend) aligns with the user's forward axis.
        // Concretely: -π/2 around Y maps Blender's +X → world +Z,
        // so the "left chair" lands in front of the user and the
        // "right chair" lands behind them.
        env.transform.rotation = simd_quatf(
            angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)
        )
        // Provisional translation — refined below once we can read
        // the cluster's bounds in world space.
        env.transform.translation = .zero

        // Balcony sconce is the env's only authored light and reads
        // as decoration; we keep its intensity (skip the dwarven-hall
        // soften pass) so the warm wash on the wall stays visible.
        content.add(env)

        // Dynamic re-anchor: find the chair+table cluster, read its
        // world-space centre after the rotation, then shift the env
        // so that centre lands at the target seated-POV position.
        if let cluster = env.findEntity(named: chairTableEntityName)
            ?? env.findEntity(named: "ChairTable_Root") {
            let b = cluster.visualBounds(relativeTo: nil)
            let target = SIMD3<Float>(
                targetClusterCenterXZ.x,
                b.center.y,
                targetClusterCenterXZ.y
            )
            env.transform.translation += (target - b.center)
        } else {
            // No cluster entity — best-effort seated-POV transform.
            env.transform.translation = SIMD3<Float>(0, 0, -0.55)
        }

        // Read the table-top position AFTER the final transform so the
        // board lands correctly on the mesh surface.
        let boardPos = EnvironmentLighting.boardPosition(
            onTableNamed: chairTableEntityName, in: env
        ) ?? SIMD3<Float>(0, 0.78, -0.55)

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
        // SUN — golden-hour directional key. visionOS RealityKit
        // wants high lumen values for a directional source to read
        // as "sunlight" against passthrough-free black; 25K is the
        // floor that makes the floor stone + railing pick up
        // visible highlights.
        let sun = DirectionalLightComponent(
            color: .init(red: 1.0, green: 0.92, blue: 0.78, alpha: 1.0),
            intensity: 25_000
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
            intensity: 700_000
        )
        sky.attenuationRadius = 14.0
        let skyEntity = Entity()
        skyEntity.name = "BalconySky"
        skyEntity.components.set(sky)
        skyEntity.position = SIMD3<Float>(0, 5.0, 0)
        content.add(skyEntity)

        // BOUNCE — warm ground-bounce so under-edges of pieces aren't
        // pure shadow on the dark stone floor.
        var bounce = PointLightComponent(
            color: .init(red: 1.0, green: 0.85, blue: 0.65, alpha: 1.0),
            intensity: 180_000
        )
        bounce.attenuationRadius = 4.0
        let bounceEntity = Entity()
        bounceEntity.name = "BalconyBounce"
        bounceEntity.components.set(bounce)
        bounceEntity.position = SIMD3<Float>(0, 0.2, 0)
        content.add(bounceEntity)
    }
}
