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

        // Surround the player with the coastal sunset panorama so
        // the view behind the railing reads as a real seascape with
        // mountains + lighthouse on the horizon. Anchored at world
        // origin with a 60 m radius — far enough that parallax is
        // negligible even when the player leans, so the horizon
        // doesn't "follow" them.
        await Self.addSkybox(into: content)

        // Glass railings: the .blend material is opaque, and the
        // Polyhaven texture's alpha doesn't survive the JPG → USDZ
        // round-trip cleanly. Walk the loaded env and substitute a
        // transparent PBR material on any entity named *Railing* so
        // the player can actually see the sea through them.
        Self.applyTransparentGlass(to: env)

        addDaylightLighting(into: content)

        return EnvironmentMount(boardPosition: boardPos)
    }

    // MARK: - Skybox / IBL

    /// Texture name in the bundle for the equirect coastal sunset
    /// panorama (Polyhaven `cape_hill`, CC0). Sized 4K equirect, JPG.
    private static let skyboxTextureName = "balcony_skybox"

    /// Builds a large inverted-normal sphere with the panorama applied
    /// as an unlit material, plus an `ImageBasedLightComponent` driven
    /// by the same image so the chairs/table/board pick up matching
    /// warm horizon reflections.
    private static func addSkybox(
        into content: any RealityViewContentProtocol
    ) async {
        let texture: TextureResource
        do {
            texture = try await TextureResource(named: skyboxTextureName)
        } catch {
            // No texture in bundle — degrade to black background.
            return
        }

        // VISUAL DOME
        // 60 m radius is well past any geometry in the balcony env
        // (cluster spans ~3 m). Flipping the sphere's X scale inverts
        // winding so the texture renders on the inside surface.
        let sphere = MeshResource.generateSphere(radius: 60)
        var unlit = UnlitMaterial()
        unlit.color = .init(tint: .white, texture: .init(texture))
        let dome = ModelEntity(mesh: sphere, materials: [unlit])
        dome.name = "BalconySkydome"
        dome.scale = SIMD3<Float>(-1, 1, 1)
        // Center on the user's seated eye level (~1.2 m above floor)
        // so the horizon line in the panorama lines up with the
        // player's gaze.
        dome.position = SIMD3<Float>(0, 1.2, 0)
        // Rotate so the sun in the texture lands behind-right of the
        // user (matches the sun directional light placed by
        // addDaylightLighting at +X +Y +Z).
        dome.transform.rotation = simd_quatf(
            angle: .pi * 0.15, axis: SIMD3<Float>(0, 1, 0)
        )
        content.add(dome)

        // IBL — same image, ensures the metal table base + chair
        // frames + board pieces all reflect the same sunset tones.
        if let envResource = try? await EnvironmentResource(
            named: skyboxTextureName
        ) {
            var ibl = ImageBasedLightComponent(source: .single(envResource))
            ibl.inheritsRotation = true
            let iblEntity = Entity()
            iblEntity.name = "BalconyIBL"
            iblEntity.components.set(ibl)
            iblEntity.components.set(
                ImageBasedLightReceiverComponent(imageBasedLight: iblEntity)
            )
            content.add(iblEntity)
        }
    }

    // MARK: - Glass override

    /// Replace the material on any entity whose name contains
    /// "Railing" or "Glass" with a transparent PBR glass material so
    /// the player can see the seascape through it. Walks the full
    /// tree so it catches `Railing_Side`, `Railing_Back_Right`, etc.
    private static func applyTransparentGlass(to root: Entity) {
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(
            tint: .init(red: 0.95, green: 0.98, blue: 1.0, alpha: 1.0)
        )
        glass.roughness = .init(floatLiteral: 0.04)
        glass.metallic = .init(floatLiteral: 0.0)
        glass.clearcoat = .init(floatLiteral: 1.0)
        glass.clearcoatRoughness = .init(floatLiteral: 0.04)
        // visionOS PBR transparency: opacity threshold lets the
        // material render with sort-correct blending.
        glass.blending = .transparent(
            opacity: .init(floatLiteral: 0.18)
        )
        glass.opacityThreshold = 0.0
        glass.faceCulling = .none

        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            let n = e.name.lowercased()
            if (n.contains("railing") || n.contains("glass")),
               let model = e as? ModelEntity {
                model.model?.materials = (model.model?.materials ?? []).map { _ in
                    glass as any RealityKit.Material
                }
            }
            stack.append(contentsOf: e.children)
        }
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
