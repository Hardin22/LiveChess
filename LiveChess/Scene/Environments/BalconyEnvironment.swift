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
        env.transform.rotation = simd_quatf(
            angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)
        )
        // Shrink the whole .blend env to ~60% so the floor matches
        // the scale of the chair / table / chess board — the
        // original 9 × 5.6 m authored floor felt like an empty
        // deck around a tiny chair cluster.
        env.transform.scale = SIMD3<Float>(repeating: 0.60)
        // Provisional translation — refined below once we can read
        // the cluster's bounds in world space.
        env.transform.translation = .zero

        // Balcony sconce is the env's only authored light and reads
        // as decoration; we keep its intensity (skip the dwarven-hall
        // soften pass) so the warm wash on the wall stays visible.
        content.add(env)

        // Dynamic re-anchor: pin the chair+table cluster centre directly
        // in front of the user via the shared helper. Same approach used
        // by every other env so the player always spawns "seated" facing
        // the board regardless of which backdrop they pick.
        let anchored = EnvironmentLighting.anchorEnvByTable(
            env,
            tableNamed: chairTableEntityName,
            frontDistance: 0.55
        ) || EnvironmentLighting.anchorEnvByTable(
            env,
            tableNamed: "ChairTable_Root",
            frontDistance: 0.55
        )
        if !anchored {
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

        // Sanitizer fixes corrupted metallic/normal maps. Keep-list
        // protects railing entities.
        Self.sanitizeBlendMaterials(in: env)
        // Glass panels are clean now (no overlapping junk fragments).
        // Swap their material to UnlitMaterial at runtime to dodge
        // visionOS's stochastic alpha for PBR transparency — the
        // panels then read as proper light blue glass.
        Self.applyTransparentGlassToRailing(in: env)
        // Hide the pot + plant pair that lives on the balcony floor.
        // User-requested removal. Targeted to PotPlant_Root and
        // PotCandle_Root specifically — keeps FirTree visible.
        Self.hidePotPlantAndVase(in: env)

        addDaylightLighting(into: content)

        return EnvironmentMount(boardPosition: boardPos)
    }

    // MARK: - Perimeter railing (procedural)

    /// Hide the .blend's bundled "Railing_*" entities — they're
    /// small decorative meshes that don't actually wrap the
    /// balcony perimeter, which is why the user kept reporting
    /// "I can't see the railings" even after we verified the
    /// geometry was in the USDZ.
    /// Hide the .blend's joined plant cluster. The 131 plants were
    /// authored across a 9 m floor and joined into a single mesh by
    /// the optimizer; on the now-scaled-down balcony they overlap
    /// awkwardly (visible as a single plant cluster clipping into
    /// the wall in the user's screenshot). Hiding the whole cluster
    /// gives a clean balcony — we can add ONE procedurally-placed
    /// pot back later if needed.
    /// Hides the bundled pot + plant arrangement (the vase + the
    /// vegetation inside it). Matches only the `PotPlant*` and
    /// `PotCandle*` subtrees — the FirTree elsewhere on the balcony
    /// stays visible. Lower-case substring match because Blender's
    /// USD exporter may sanitize underscores or casing.
    private static func hidePotPlantAndVase(in root: Entity) {
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            let n = e.name.lowercased()
            if n.contains("potplant") || n.contains("pot_plant")
                || n.contains("potcandle") || n.contains("pot_candle")
                || n.contains("vase") {
                e.isEnabled = false
                // No need to walk this subtree — disabling the
                // root hides every descendant.
                continue
            }
            stack.append(contentsOf: e.children)
        }
    }

    private static func hideOriginalPlants(in root: Entity) {
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            let n = e.name.lowercased()
            if n.contains("plant") || n.contains("pot")
                || n.contains("foliage") || n.contains("fir")
                || n.contains("tree") || n.contains("leaf") {
                e.isEnabled = false
            }
            stack.append(contentsOf: e.children)
        }
    }

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
        let floorY = bounds.max.y

        let railingRoot = Entity()
        railingRoot.name = "ProceduralRailing"
        content.add(railingRoot)

        // FRONT (sea-facing) — full width, corner to corner.
        // This is the ONLY open side now that the env has wood-plank
        // walls on left, right, and back (with a door cut into the
        // back wall). The right-side railing was removed because the
        // new right wall sits at that floor edge and the glass would
        // clip into it.
        addRailingRun(start: SIMD3<Float>(minX, floorY, frontZ),
                      end:   SIMD3<Float>(maxX, floorY, frontZ),
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

    // MARK: - Material sanitizer

    /// The .blend's textures were downscaled + JPG re-encoded by our
    /// optimizer. That pass mangled the **metallic** and **normal**
    /// maps in particular — on device every wood plank + chair panel
    /// composites as splotchy chrome with fake mirror reflections of
    /// the skybox (clearly visible on the wall and the chair).
    ///
    /// Walk every ModelEntity under the env and rebuild each material
    /// from scratch: keep only the baseColor (tint + texture), force
    /// metallic to 0, give it a believable wood-ish roughness, and
    /// drop the corrupted normal / clearcoat maps. The result reads
    /// as plain matte surfaces with their original brown colour, no
    /// chrome blowout.
    ///
    /// The procedural chrome / glass railing we mount AFTER this
    /// call is unaffected because we build those entities fresh with
    /// our own material.
    private static func sanitizeBlendMaterials(in root: Entity) {
        // Flat warm walnut for surfaces with corrupted textures.
        // PBR with roughness=1, metallic=0 → fully matte, no IBL
        // mirror reflection possible. Drop the baseColor texture
        // because the user's screenshot showed the blotchy pattern
        // was BAKED into the texture (not just metallic on top).
        var walnut = PhysicallyBasedMaterial()
        walnut.baseColor = .init(
            tint: .init(red: 0.42, green: 0.28, blue: 0.19, alpha: 1.0)
        )
        walnut.roughness = .init(floatLiteral: 1.0)
        walnut.metallic = .init(floatLiteral: 0.0)

        // Entity names we explicitly want to PRESERVE — these surfaces
        // looked fine in the user's screenshot (stone floor, foliage,
        // pot, lantern candle).
        let keepKeywords = [
            "balcony_floor", "floor",
            "plant", "pot", "foliage", "leaf", "fir", "tree",
            "lantern", "candle",
            "proceduralrailing", "balconyskirt", "balconyskydome",
            // New room walls + door use clean PolyHaven materials
            // (brown_planks_03 / dark_wooden_planks). They MUST be
            // preserved — overriding them with flat walnut wipes the
            // textured plank look the .blend was authored with.
            "wall_", "door_",
            // The user wants the .blend's authored glass panel +
            // railing to render exactly as in the USDZ, so the
            // sanitizer must NOT touch them.
            "railing", "glass",
        ]

        var touched = 0, preserved = 0
        var stack: [(Entity, String)] = [(root, "")]
        while let (e, parentChain) = stack.popLast() {
            let chain = parentChain + "/" + e.name
            for c in e.children {
                stack.append((c, chain))
            }
            // Use COMPONENT access — USD-loaded geometry attaches
            // ModelComponent to plain Entity, not ModelEntity, which
            // is why the previous pass skipped the wall + chair.
            guard var comp = e.components[ModelComponent.self] else {
                continue
            }
            let lower = chain.lowercased()
            let shouldKeep = keepKeywords.contains { lower.contains($0) }
            if shouldKeep {
                preserved += 1
                continue
            }
            let count = max(comp.materials.count, 1)
            comp.materials = Array(
                repeating: walnut as any RealityKit.Material,
                count: count
            )
            e.components.set(comp)
            touched += 1
            print("  walnut → \(chain)")
        }
        print("=== sanitize: \(touched) overridden, \(preserved) preserved ===")
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

    /// Swap the joined railing's chrome material for a tinted
    /// semi-transparent glass material. Acts on USD-loaded entities
    /// (plain `Entity` with `ModelComponent`) — the earlier
    /// `applyTransparentGlass(to:)` used `as? ModelEntity` which
    /// skips USDZ-loaded geometry.
    ///
    /// Matches on entity name (anything containing "railing" or
    /// "glass") and overrides ALL material slots on each match. The
    /// in-Blender chrome posts share a single material slot with the
    /// glass panels (Steel_Chrome) because the 11k railing objects
    /// were joined into one mesh during optimization — so both posts
    /// and panels get glass. Posts are thin enough that the loss is
    /// visually negligible, but the panels read as glass against the
    /// sea view instead of as a black mirror.
    /// Build 3 fresh glass panel quads in Swift and add them as
    /// children of the env. Procedural meshes bypass the USDZ
    /// loading pipeline that was producing dither artifacts on the
    /// authored Cube mesh.
    ///
    /// Local positions match the 3 panels' centers in the .blend:
    ///   * back-right (Blender +X half of back rail)
    ///   * back-left  (Blender -X half of back rail)
    ///   * left side  (perpendicular run along Blender Y)
    private static func addProceduralGlassPanels(into env: Entity) {
        // Find the (now-hidden) Railing_Glass Xform — it sits at the
        // correct world position for the back-right panel after all
        // the env rotations/scales. We parent the procedural planes
        // to it so they automatically inherit the correct world
        // transform without us having to do axis math.
        var anchor: Entity?
        var stack: [Entity] = [env]
        while let e = stack.popLast() {
            if e.name == "Railing_Glass" {
                anchor = e
                break
            }
            stack.append(contentsOf: e.children)
        }
        guard let railingGlass = anchor else {
            print("Railing_Glass anchor not found — skipping proc panels")
            return
        }
        // Make sure the anchor is enabled (even though its mesh is
        // hidden via the child entity). The anchor itself needs to
        // be active so its world transform stays current.
        railingGlass.isEnabled = true

        var mat = UnlitMaterial(
            color: .init(red: 0.42, green: 0.65, blue: 0.90, alpha: 0.80)
        )
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.80))
        mat.opacityThreshold = 0.0
        mat.faceCulling = .none  // visible from either side

        // Panel offsets relative to Railing_Glass Xform's origin
        // (which sits at the back-right panel's center). The .blend
        // Z-up was converted to Y-up on USDZ export, so what was
        // .blend's +Z (vertical) is now +Y in Railing_Glass's local
        // frame, and what was .blend's +Y (forward) is now -Z (back
        // away from the sea).
        //
        // panel positions in Blender world were:
        //   BackRight: (+1.06, +1.55, +0.55)
        //   BackLeft : (-1.06, +1.55, +0.55)
        //   Side     : (-2.05, +0.76, +0.55)
        // → relative to BackRight, after the Y↔Z axis swap (USDZ):
        //   BackRight: ( 0.00, 0,  0.00)
        //   BackLeft : (-2.12, 0,  0.00)
        //   Side     : (-3.11, 0, +0.79)   ← +0.79 along USDZ +Z
        //
        // Thin Box mesh keeps the default RealityKit axes — width=X,
        // height=Y (up), depth=Z — so the panel stands vertical with
        // no extra rotation. The Side panel just gets a 90° yaw
        // around Y so its long axis runs along Z instead of X.
        let panels: [(String, Float, Float, Float, Float, Float, Float)] = [
            // name,  lx,   ly, lz,    width, heightY, yawAroundY°
            ("ProcGlass_BackRight",  0.00, 0.00,  0.00, 1.878, 0.910,  0),
            ("ProcGlass_BackLeft", -2.12, 0.00,  0.00, 1.877, 0.910,  0),
            ("ProcGlass_Side",     -3.11, 0.00,  0.79, 1.401, 0.910, 90),
        ]

        for (name, lx, ly, lz, w, h, yawDeg) in panels {
            let mesh = MeshResource.generateBox(
                width: w, height: h, depth: 0.005
            )
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = name
            let yaw = yawDeg * .pi / 180
            entity.transform.rotation = simd_quatf(
                angle: yaw, axis: SIMD3<Float>(0, 1, 0)
            )
            entity.transform.translation = SIMD3<Float>(lx, ly, lz)
            railingGlass.addChild(entity)
            print("  proc glass panel: \(name) local=(\(lx),\(ly),\(lz))")
        }
    }

    /// Hide every entity in the loaded env whose name contains
    /// "glass". Used to suppress the broken Railing_Glass panel
    /// without re-exporting.
    private static func hideGlassEntities(in root: Entity) {
        // Only hide entities that actually carry a ModelComponent
        // (i.e. renderable meshes). Leaves Xform anchors enabled so
        // procedural children can inherit their world transform.
        func ancestorMatchesGlass(_ start: Entity) -> Bool {
            var cur: Entity? = start
            while let c = cur {
                if c.name.lowercased().contains("glass") { return true }
                cur = c.parent
            }
            return false
        }
        var hidden = 0
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            stack.append(contentsOf: e.children)
            guard ancestorMatchesGlass(e) else { continue }
            guard e.components[ModelComponent.self] != nil else { continue }
            e.isEnabled = false
            hidden += 1
            print("  hidden glass mesh entity: \(e.name)")
        }
        print("=== glass mesh entities hidden: \(hidden) ===")
    }

    private static func applyTransparentGlassToRailing(in root: Entity) {
        // Use UnlitMaterial instead of PhysicallyBasedMaterial — the
        // PBR pipeline on visionOS falls back to stochastic / dithered
        // alpha at low opacity which produced the black-stipple
        // splotches the user reported. UnlitMaterial uses straight
        // alpha blending (no dither, no PBR shadow path), so the
        // panel reads as a clean tinted glass.
        // 80% opaque sky blue. Pushed well above the alpha threshold
        // where visionOS dithers transparency (which produced the
        // earlier cloud-stipple splotches) while still letting the
        // sea view come through a bit. Hint of see-through, no dots.
        var glassUnlit = UnlitMaterial(
            color: .init(red: 0.42, green: 0.65, blue: 0.90, alpha: 0.80)
        )
        glassUnlit.blending = .transparent(
            opacity: .init(floatLiteral: 0.80)
        )
        glassUnlit.opacityThreshold = 0.0
        glassUnlit.faceCulling = .back
        let glass: any RealityKit.Material = glassUnlit

        // Walk every entity. Apply the glass override when EITHER the
        // entity itself OR any ancestor's name contains "glass". The
        // glass mesh is a child Mesh named "Cube" under the Xform
        // "Railing_Glass", so matching only on the entity's own name
        // misses it.
        func ancestorMatchesGlass(_ start: Entity) -> Bool {
            var cur: Entity? = start
            while let c = cur {
                if c.name.lowercased().contains("glass") { return true }
                cur = c.parent
            }
            return false
        }
        var touched = 0
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            stack.append(contentsOf: e.children)
            guard ancestorMatchesGlass(e) else { continue }
            guard var comp = e.components[ModelComponent.self] else {
                continue
            }
            let count = max(comp.materials.count, 1)
            comp.materials = Array(
                repeating: glass as any RealityKit.Material,
                count: count
            )
            e.components.set(comp)
            touched += 1
            print("  glass override → '\(e.name)' (matCount=\(count))")
        }
        print("=== transparent-glass override: \(touched) entities ===")
    }

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
