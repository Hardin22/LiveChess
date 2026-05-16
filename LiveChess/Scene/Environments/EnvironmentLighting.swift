import Foundation
import RealityKit

/// Shared lighting helpers used by every `EnvironmentScene`.
///
///   * `softenEmbeddedLights` — walks the loaded USDZ's entity tree
///     and halves any baked-in real-time lights so the env author's
///     hard ring/cone artefacts don't fight our authored key/rim.
///   * `startFlicker` — superimposed-sine flicker on a `PointLightComponent`.
///     Implicitly cancelled when the entity deallocs (weak capture).
@MainActor
enum EnvironmentLighting {

    /// Reduces baked PointLight / SpotLight intensity ×0.35 and widens
    /// their attenuation radius so embedded fixtures fade gradually
    /// instead of ending in a hard ring on the floor.
    static func softenEmbeddedLights(in root: Entity) {
        var stack: [Entity] = [root]
        while let entity = stack.popLast() {
            if var p = entity.components[PointLightComponent.self] {
                p.intensity = p.intensity * 0.35
                p.attenuationRadius = max(p.attenuationRadius * 2.5, 6.0)
                entity.components.set(p)
            }
            if var s = entity.components[SpotLightComponent.self] {
                s.intensity = s.intensity * 0.35
                s.attenuationRadius = max(s.attenuationRadius * 2.5, 6.0)
                s.outerAngleInDegrees = min(s.outerAngleInDegrees * 1.4, 175)
                entity.components.set(s)
            }
            stack.append(contentsOf: entity.children)
        }
    }

    /// Drives an organic-looking intensity flicker on a `PointLightComponent`
    /// using two superimposed sine waves at different frequencies.
    static func startFlicker(
        on entity: Entity,
        baseIntensity: Float,
        amplitude: Float,
        period: Double
    ) {
        Task { @MainActor [weak entity] in
            let start = Date()
            while !Task.isCancelled {
                guard let entity = entity else { return }
                let elapsed = Date().timeIntervalSince(start)
                let phase = (elapsed / period) * 2.0 * .pi
                let secondary = (elapsed / (period * 0.43)) * 2.0 * .pi
                let mix = (sin(phase) * 0.7 + sin(secondary) * 0.3)
                let modulator = Float(mix) * amplitude
                let newIntensity = baseIntensity * (1.0 + modulator)
                if var p = entity.components[PointLightComponent.self] {
                    p.intensity = newIntensity
                    entity.components.set(p)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Resolves the world-space top of a named entity in the loaded env,
    /// lifted by `lift` to avoid z-fighting the table mesh.
    static func boardPosition(
        onTableNamed name: String,
        in env: Entity,
        lift: Float = 0.006
    ) -> SIMD3<Float>? {
        guard let table = env.findEntity(named: name) else { return nil }
        let bounds = table.visualBounds(relativeTo: nil)
        let topY = bounds.center.y + bounds.extents.y / 2
        return SIMD3<Float>(bounds.center.x, topY + lift, bounds.center.z)
    }
}
