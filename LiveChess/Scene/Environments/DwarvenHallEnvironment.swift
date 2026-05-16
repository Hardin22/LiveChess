import Foundation
import RealityKit
import SwiftUI

/// Loads `Resources/environment.usdz` (the colleague's dwarven chess
/// hall — table + chairs + sconces + statues + arches) and applies the
/// seated-POV transform plus the cinematic noir lighting + dust motes
/// designed for it.
///
/// Originally inlined in `ChessSceneView`; lifted out so each env owns
/// its own mounting / lighting code and the view stays a switch over
/// `SceneEnvironment`.
@MainActor
enum DwarvenHallEnvironment: EnvironmentScene {

    static func mount(
        into content: any RealityViewContentProtocol
    ) async -> EnvironmentMount? {
        let env: Entity
        do {
            env = try await Entity(named: "environment", in: .main)
        } catch {
            return nil
        }
        env.name = "VirtualEnvironment_DwarvenHall"

        // Seated-POV transform from the env author's reference scene.
        // Black chair sits at (9, 0, 0.62) facing -X toward the table.
        // Rotating -π/2 around Y maps chair-forward (-X) to user-forward
        // (-Z), and translating by (0, +0.3, -9.15) lands the chair eye
        // at the user's natural standing eye level near world origin.
        env.transform.rotation = simd_quatf(
            angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)
        )
        env.position = SIMD3<Float>(0, 0.3, -9.15)

        EnvironmentLighting.softenEmbeddedLights(in: env)
        content.add(env)

        guard let table = env.findEntity(named: "AntiqueTable") else {
            return nil
        }
        let bounds = table.visualBounds(relativeTo: nil)
        let tableTopY = bounds.center.y + bounds.extents.y / 2
        // ~6 mm lift above the table mesh so the board frame doesn't
        // z-fight the table surface.
        let lift: Float = 0.006
        let boardPosition = SIMD3<Float>(
            bounds.center.x, tableTopY + lift, bounds.center.z
        )

        addNoirLighting(into: content)
        addDustMotes(into: content)

        return EnvironmentMount(boardPosition: boardPosition)
    }

    /// Four-light noir setup tuned to this hall:
    ///   - KEY: tight warm spot directly above the table.
    ///   - RIM: warm molten-gold accent from far behind the room.
    ///   - FILL: cool counter-light behind the user.
    ///   - TABLE FILL: small warm pool at table height for piece readability.
    private static func addNoirLighting(
        into content: any RealityViewContentProtocol
    ) {
        var key = SpotLightComponent(
            color: .init(red: 1.0, green: 0.78, blue: 0.45, alpha: 1.0),
            intensity: 800_000
        )
        key.attenuationRadius = 4.0
        key.innerAngleInDegrees = 30
        key.outerAngleInDegrees = 75
        let keyEntity = Entity()
        keyEntity.name = "DwarvenKey"
        keyEntity.components.set(key)
        keyEntity.look(
            at: SIMD3<Float>(0, 0.7, -1.0),
            from: SIMD3<Float>(0, 4.5, -1.0),
            relativeTo: nil
        )
        content.add(keyEntity)

        var rim = PointLightComponent(
            color: .init(red: 1.0, green: 0.45, blue: 0.12, alpha: 1.0),
            intensity: 1_200_000
        )
        rim.attenuationRadius = 18.0
        let rimEntity = Entity()
        rimEntity.name = "DwarvenRim"
        rimEntity.components.set(rim)
        rimEntity.position = SIMD3<Float>(0, 4.0, -12.0)
        content.add(rimEntity)
        EnvironmentLighting.startFlicker(
            on: rimEntity,
            baseIntensity: 1_200_000,
            amplitude: 0.18,
            period: 2.7
        )

        var fill = PointLightComponent(
            color: .init(red: 0.45, green: 0.55, blue: 0.85, alpha: 1.0),
            intensity: 150_000
        )
        fill.attenuationRadius = 14.0
        let fillEntity = Entity()
        fillEntity.name = "DwarvenFill"
        fillEntity.components.set(fill)
        fillEntity.position = SIMD3<Float>(0, 2.5, 5.0)
        content.add(fillEntity)

        var tableFill = PointLightComponent(
            color: .init(red: 1.0, green: 0.82, blue: 0.55, alpha: 1.0),
            intensity: 22_000
        )
        tableFill.attenuationRadius = 2.4
        let tableFillEntity = Entity()
        tableFillEntity.name = "DwarvenTableFill"
        tableFillEntity.components.set(tableFill)
        tableFillEntity.position = SIMD3<Float>(0, 1.0, -1.0)
        content.add(tableFillEntity)
        EnvironmentLighting.startFlicker(
            on: tableFillEntity,
            baseIntensity: 22_000,
            amplitude: 0.10,
            period: 1.9
        )
    }

    /// Drifting dust motes through the warm key beam.
    private static func addDustMotes(
        into content: any RealityViewContentProtocol
    ) {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = SIMD3<Float>(2.5, 2.0, 2.5)
        emitter.birthLocation = .volume
        emitter.birthDirection = .normal
        emitter.timing = .repeating(
            warmUp: 8.0,
            emit: .init(duration: .infinity),
            idle: nil
        )
        var main = emitter.mainEmitter
        main.birthRate = 35
        main.lifeSpan = 18
        main.lifeSpanVariation = 6
        main.size = 0.006
        main.sizeVariation = 0.003
        main.color = .constant(.single(
            .init(red: 1.0, green: 0.88, blue: 0.65, alpha: 0.8)
        ))
        main.opacityCurve = .gradualFadeInOut
        main.spreadingAngle = 0.5
        main.acceleration = SIMD3<Float>(0, -0.02, 0)
        main.angularSpeed = 0.2
        main.angularSpeedVariation = 0.1
        emitter.mainEmitter = main
        emitter.speed = 0.04
        emitter.speedVariation = 0.02

        let entity = Entity()
        entity.name = "DustMotes"
        entity.components.set(emitter)
        entity.position = SIMD3<Float>(0, 2.5, -1.0)
        content.add(entity)
    }
}
