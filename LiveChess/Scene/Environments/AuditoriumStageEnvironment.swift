import Foundation
import RealityKit
import SwiftUI

/// Loads `Resources/auditorium-stage.usdz` (a conference-style stage
/// with a central player table flanked by two presenter chairs, three
/// banked seat sections facing the stage, truss-mounted spotlights, a
/// silver podium frame, decorative plants, and an LED backwall).
///
/// The Blender source preserves a top-level `Table` Xform in the
/// USDZ — we look that up to seat the board on top of it.
@MainActor
enum AuditoriumStageEnvironment: EnvironmentScene {

    private static let tableEntityName = "Table"

    static func mount(
        into content: any RealityViewContentProtocol
    ) async -> EnvironmentMount? {
        let env: Entity
        do {
            env = try await Entity(named: "auditorium-stage", in: .main)
        } catch {
            return nil
        }
        env.name = "VirtualEnvironment_AuditoriumStage"

        // Authored facing forward (-Z after Y-up conversion). No
        // rotation; pull the user slightly back from the stage centre
        // so the player chair lands in front of the seated POV.
        env.transform.rotation = simd_quatf(
            angle: 0, axis: SIMD3<Float>(0, 1, 0)
        )
        env.position = SIMD3<Float>(0, 0.0, -0.4)

        EnvironmentLighting.softenEmbeddedLights(in: env)
        content.add(env)

        let boardPos = EnvironmentLighting.boardPosition(
            onTableNamed: tableEntityName, in: env
        ) ?? SIMD3<Float>(0, 0.78, 0)

        addAuditoriumLighting(into: content)

        return EnvironmentMount(boardPosition: boardPos)
    }

    /// Auditorium / conference stage lighting:
    ///   - KEY: warm white spot from above the player table.
    ///   - PRESENTER RIM: cool side-light from upstage left to give
    ///     the chairs a clean silhouette against the backwall.
    ///   - HOUSE FILL: low warm fill across the audience banks so the
    ///     seats read as a soft glow rather than black holes.
    ///   - SCREEN GLOW: subtle blue fill from the LED backwall.
    private static func addAuditoriumLighting(
        into content: any RealityViewContentProtocol
    ) {
        var key = SpotLightComponent(
            color: .init(red: 1.0, green: 0.94, blue: 0.85, alpha: 1.0),
            intensity: 900_000
        )
        key.attenuationRadius = 5.0
        key.innerAngleInDegrees = 28
        key.outerAngleInDegrees = 62
        let keyEntity = Entity()
        keyEntity.name = "AuditoriumKey"
        keyEntity.components.set(key)
        keyEntity.look(
            at: SIMD3<Float>(0, 0.7, 0),
            from: SIMD3<Float>(0, 5.0, 0.5),
            relativeTo: nil
        )
        content.add(keyEntity)

        var rim = SpotLightComponent(
            color: .init(red: 0.70, green: 0.85, blue: 1.0, alpha: 1.0),
            intensity: 450_000
        )
        rim.attenuationRadius = 6.0
        rim.innerAngleInDegrees = 35
        rim.outerAngleInDegrees = 65
        let rimEntity = Entity()
        rimEntity.name = "AuditoriumRim"
        rimEntity.components.set(rim)
        rimEntity.look(
            at: SIMD3<Float>(0, 0.9, 0),
            from: SIMD3<Float>(-3.2, 3.0, -1.5),
            relativeTo: nil
        )
        content.add(rimEntity)

        var house = PointLightComponent(
            color: .init(red: 1.0, green: 0.88, blue: 0.70, alpha: 1.0),
            intensity: 180_000
        )
        house.attenuationRadius = 14.0
        let houseEntity = Entity()
        houseEntity.name = "AuditoriumHouse"
        houseEntity.components.set(house)
        houseEntity.position = SIMD3<Float>(0, 3.5, 6.0)
        content.add(houseEntity)

        var screen = PointLightComponent(
            color: .init(red: 0.30, green: 0.55, blue: 1.0, alpha: 1.0),
            intensity: 220_000
        )
        screen.attenuationRadius = 10.0
        let screenEntity = Entity()
        screenEntity.name = "AuditoriumScreen"
        screenEntity.components.set(screen)
        screenEntity.position = SIMD3<Float>(0, 2.6, -3.2)
        content.add(screenEntity)
    }
}
