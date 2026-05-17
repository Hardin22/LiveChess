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

        // The .blend's bundled railings aren't actually at the
        // floor perimeter — they're small decorative meshes near
        // the chair. Hide them and spawn a proper procedural
        // perimeter railing (chrome posts + tinted glass panels)
        // around the actual Balcony_Floor edges so the player
        // always sees a clean balcony fence between themselves
        // and the sea.
        Self.hideOriginalRailings(in: env)
        Self.addFloorSkirt(around: env, into: content)
        Self.addPerimeterRailing(around: env, into: content)

        addDaylightLighting(into: content)

        return EnvironmentMount(boardPosition: boardPos)
    }

    // MARK: - Perimeter railing (procedural)

    /// Hide the .blend's bundled "Railing_*" entities — they're
    /// small decorative meshes that don't actually wrap the
    /// balcony perimeter, which is why the user kept reporting
    /// "I can't see the railings" even after we verified the
    /// geometry was in the USDZ.
    private static func hideOriginalRailings(in root: Entity) {
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            if e.name.lowercased().contains("railing") {
                e.isEnabled = false
            }
            stack.append(contentsOf: e.children)
        }
    }

    /// Drop a thick stone-coloured slab directly beneath the
    /// Balcony_Floor so the platform reads as a real concrete /
    /// stone balcony instead of a paper-thin tile pad floating
    /// over the mountainside. Extends 15 cm beyond each edge so
    /// the visible "rim" forms a clean shadow line under the
    /// front + right glass railings.
    private static func addFloorSkirt(
        around env: Entity,
        into content: any RealityViewContentProtocol
    ) {
        let floor = env.findEntity(named: "Balcony_Floor")
        let bounds: BoundingBox = floor.map { $0.visualBounds(relativeTo: nil) }
            ?? BoundingBox(
                min: SIMD3<Float>(-3.0, 0, -3.0),
                max: SIMD3<Float>( 3.0, 0,  0.0)
            )

        // 30 cm of structural mass under the tile surface.
        let skirtThickness: Float = 0.30
        let overhang: Float = 0.05
        let widthX = (bounds.max.x - bounds.min.x) + overhang * 2
        let widthZ = (bounds.max.z - bounds.min.z) + overhang * 2
        let centreX = (bounds.min.x + bounds.max.x) / 2
        let centreZ = (bounds.min.z + bounds.max.z) / 2
        // Position the skirt so its TOP is flush with the floor's
        // underside (bounds.min.y), thickness goes downward.
        let topY = bounds.min.y - 0.001    // hair below the floor surface
        let centreY = topY - skirtThickness / 2

        var skirtMaterial = PhysicallyBasedMaterial()
        skirtMaterial.baseColor = .init(
            tint: .init(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
        )
        skirtMaterial.roughness = .init(floatLiteral: 0.85)
        skirtMaterial.metallic = .init(floatLiteral: 0)

        let skirt = ModelEntity(
            mesh: .generateBox(size: [widthX, skirtThickness, widthZ],
                               cornerRadius: 0.01),
            materials: [skirtMaterial]
        )
        skirt.position = SIMD3<Float>(centreX, centreY, centreZ)
        skirt.name = "BalconySkirt"
        content.add(skirt)
    }

    /// Build a chrome + glass railing along the open edges of the
    /// balcony — the front (sea-facing) AND the right side, both of
    /// which drop off to rocks. Left side stays open because that's
    /// the wooden wall, back stays open because that's the interior.
    private static func addPerimeterRailing(
        around env: Entity,
        into content: any RealityViewContentProtocol
    ) {
        let floor = env.findEntity(named: "Balcony_Floor")
        let bounds: BoundingBox = floor.map { $0.visualBounds(relativeTo: nil) }
            ?? BoundingBox(
                min: SIMD3<Float>(-3.0, 0, -3.0),
                max: SIMD3<Float>( 3.0, 0,  0.0)
            )
        print("=== balcony floor world bounds ===")
        print("  min=\(bounds.min)  max=\(bounds.max)  extents=\(bounds.extents)")

        let inset: Float = 0.05
        let minX = bounds.min.x + inset
        let maxX = bounds.max.x - inset
        let frontZ = bounds.min.z
        let backZ = bounds.max.z - inset
        let floorY = bounds.max.y

        let railingRoot = Entity()
        railingRoot.name = "ProceduralRailing"
        content.add(railingRoot)

        // FRONT (sea-facing) — full width, corner to corner
        addRailingRun(start: SIMD3<Float>(minX, floorY, frontZ),
                      end:   SIMD3<Float>(maxX, floorY, frontZ),
                      parent: railingRoot)

        // RIGHT side — from the front-right corner back to the
        // wall. Same chrome + glass treatment, joins seamlessly
        // with the front run at the corner.
        addRailingRun(start: SIMD3<Float>(maxX, floorY, frontZ),
                      end:   SIMD3<Float>(maxX, floorY, backZ),
                      parent: railingRoot)
    }

    /// One straight run of railing between two world-space points.
    /// Builds: vertical chrome posts every 1.5 m, a continuous
    /// top + bottom chrome rail, and a tinted glass panel between
    /// every pair of posts.
    private static func addRailingRun(
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        parent: Entity
    ) {
        let railingHeight: Float = 1.0
        let postRadius: Float = 0.012
        let railRadius: Float = 0.010
        let postSpacing: Float = 1.5

        let chrome = chromeMaterial()
        let glass = glassMaterial()

        let dx = end.x - start.x
        let dz = end.z - start.z
        let runLength = sqrt(dx * dx + dz * dz)
        guard runLength > 0.1 else { return }
        let ux = dx / runLength
        let uz = dz / runLength
        // Perpendicular for panel orientation
        let nx = -uz
        let nz =  ux
        _ = (nx, nz) // silence "unused" — kept for future panel-tilt tuning

        // Vertical posts
        let postCount = max(2, Int(runLength / postSpacing) + 1)
        let postStep = runLength / Float(postCount - 1)
        var postPositions: [SIMD3<Float>] = []
        for i in 0..<postCount {
            let t = Float(i) * postStep
            let p = SIMD3<Float>(
                start.x + ux * t,
                start.y + railingHeight / 2,
                start.z + uz * t
            )
            postPositions.append(p)
            let post = ModelEntity(
                mesh: .generateCylinder(height: railingHeight,
                                        radius: postRadius),
                materials: [chrome]
            )
            post.position = p
            parent.addChild(post)
        }

        // Top + bottom continuous rails (chrome boxes along the run)
        for yOffset in [Float(railingHeight - railRadius),
                        Float(railRadius)] {
            let rail = ModelEntity(
                mesh: .generateBox(
                    size: [runLength, railRadius * 2, railRadius * 2],
                    cornerRadius: railRadius
                ),
                materials: [chrome]
            )
            let mid = SIMD3<Float>(
                (start.x + end.x) / 2,
                start.y + yOffset,
                (start.z + end.z) / 2
            )
            rail.position = mid
            // Rotate so the box's local X aligns with the run direction.
            let angle = atan2(dx, dz) - .pi / 2
            rail.transform.rotation = simd_quatf(
                angle: angle, axis: SIMD3<Float>(0, 1, 0)
            )
            parent.addChild(rail)
        }

        // Glass panels between adjacent posts
        for i in 0..<(postPositions.count - 1) {
            let a = postPositions[i]
            let b = postPositions[i + 1]
            let panelLen = simd_distance(SIMD3<Float>(a.x, 0, a.z),
                                         SIMD3<Float>(b.x, 0, b.z))
                - postRadius * 2
            guard panelLen > 0.05 else { continue }
            let panel = ModelEntity(
                mesh: .generateBox(
                    size: [panelLen, railingHeight - railRadius * 4, 0.006],
                    cornerRadius: 0.002
                ),
                materials: [glass]
            )
            let mid = SIMD3<Float>(
                (a.x + b.x) / 2,
                start.y + railingHeight / 2,
                (a.z + b.z) / 2
            )
            panel.position = mid
            let angle = atan2(b.x - a.x, b.z - a.z) - .pi / 2
            panel.transform.rotation = simd_quatf(
                angle: angle, axis: SIMD3<Float>(0, 1, 0)
            )
            parent.addChild(panel)
        }
    }

    private static func chromeMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .init(white: 0.85, alpha: 1))
        m.metallic = .init(floatLiteral: 1.0)
        m.roughness = .init(floatLiteral: 0.18)
        return m
    }

    private static func glassMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(
            tint: .init(red: 0.55, green: 0.78, blue: 0.92, alpha: 1)
        )
        m.metallic = .init(floatLiteral: 0)
        m.roughness = .init(floatLiteral: 0.05)
        m.clearcoat = .init(floatLiteral: 1.0)
        m.clearcoatRoughness = .init(floatLiteral: 0.05)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        m.faceCulling = .none
        return m
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
    /// "Railing" or "Glass" with a SEMI-transparent tinted glass +
    /// thin chrome edge so the panels actually read as glass (you
    /// can see through them) instead of vanishing into the skybox.
    ///
    /// Previous tuning at opacity 0.18 against the bright Polyhaven
    /// sunset HDRI was effectively invisible — the user reported the
    /// railing "totally disappeared." 0.45 opacity + a cool cyan
    /// tint + a thin edge stroke pull the silhouette back into view
    /// while still letting the sea show through behind the glass.
    private static func applyTransparentGlass(to root: Entity) {
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(
            tint: .init(red: 0.55, green: 0.78, blue: 0.92, alpha: 1.0)
        )
        glass.roughness = .init(floatLiteral: 0.06)
        glass.metallic = .init(floatLiteral: 0.0)
        glass.clearcoat = .init(floatLiteral: 1.0)
        glass.clearcoatRoughness = .init(floatLiteral: 0.04)
        // 0.45 is the sweet spot: glass clearly reads as a surface,
        // but you can still see the sea behind it.
        glass.blending = .transparent(
            opacity: .init(floatLiteral: 0.45)
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
