import Foundation
import RealityKit
import simd

/// Mesh helpers that go beyond what `MeshResource.generate*` exposes:
///   * `tiledBox` — a box with explicit UV scaling per face, so a
///     texture can tile multiple times across a large slab at the
///     same physical density as on a small mesh.
///   * `reUVCylindrical` — re-projects every vertex's UVs of an
///     entity tree's meshes onto a cylindrical wrap around the Y
///     axis. Used to repair the broken UVs that downloaded chess
///     piece USDZs ship with — mostly-rotationally-symmetric pieces
///     read much better with a cylinder map than with whatever
///     unwrap the modeller threw together.
@MainActor
enum MeshFactory {

    // MARK: - Tiled box

    /// Builds a flat-shaded box with explicit per-face UVs. Top and
    /// bottom faces tile the texture by `topTiles`; the four side
    /// faces tile by `sideTiles`. Combined with a sampler in
    /// `.repeat` address mode, this gives a large slab the same
    /// per-cm grain density as a small tile sampling the same
    /// texture. Used for the board frame so its wood grain matches
    /// the squares' grain instead of stretching across the whole
    /// 55-cm slab.
    static func tiledBox(
        size: SIMD3<Float>,
        topTiles: SIMD2<Float>,
        sideTiles: SIMD2<Float>
    ) -> MeshResource {
        let h = size / 2
        let positions: [SIMD3<Float>] = [
            // +Y top
            [-h.x, +h.y, +h.z], [+h.x, +h.y, +h.z], [+h.x, +h.y, -h.z], [-h.x, +h.y, -h.z],
            // -Y bottom
            [-h.x, -h.y, -h.z], [+h.x, -h.y, -h.z], [+h.x, -h.y, +h.z], [-h.x, -h.y, +h.z],
            // +Z front
            [-h.x, -h.y, +h.z], [+h.x, -h.y, +h.z], [+h.x, +h.y, +h.z], [-h.x, +h.y, +h.z],
            // -Z back
            [+h.x, -h.y, -h.z], [-h.x, -h.y, -h.z], [-h.x, +h.y, -h.z], [+h.x, +h.y, -h.z],
            // +X right
            [+h.x, -h.y, +h.z], [+h.x, -h.y, -h.z], [+h.x, +h.y, -h.z], [+h.x, +h.y, +h.z],
            // -X left
            [-h.x, -h.y, -h.z], [-h.x, -h.y, +h.z], [-h.x, +h.y, +h.z], [-h.x, +h.y, -h.z]
        ]
        let normals: [SIMD3<Float>] = [
            [0,1,0],[0,1,0],[0,1,0],[0,1,0],
            [0,-1,0],[0,-1,0],[0,-1,0],[0,-1,0],
            [0,0,1],[0,0,1],[0,0,1],[0,0,1],
            [0,0,-1],[0,0,-1],[0,0,-1],[0,0,-1],
            [1,0,0],[1,0,0],[1,0,0],[1,0,0],
            [-1,0,0],[-1,0,0],[-1,0,0],[-1,0,0]
        ]
        let tT = topTiles
        let sT = sideTiles
        let uvs: [SIMD2<Float>] = [
            [0,0], [tT.x,0], [tT.x,tT.y], [0,tT.y],   // top
            [0,0], [tT.x,0], [tT.x,tT.y], [0,tT.y],   // bottom
            [0,0], [sT.x,0], [sT.x,sT.y], [0,sT.y],   // front
            [0,0], [sT.x,0], [sT.x,sT.y], [0,sT.y],   // back
            [0,0], [sT.x,0], [sT.x,sT.y], [0,sT.y],   // right
            [0,0], [sT.x,0], [sT.x,sT.y], [0,sT.y]    // left
        ]
        var triangles: [UInt32] = []
        triangles.reserveCapacity(36)
        for face in 0..<6 {
            let b = UInt32(face * 4)
            triangles.append(contentsOf: [b, b+1, b+2, b, b+2, b+3])
        }

        var descriptor = MeshDescriptor(name: "TiledBox")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(triangles)

        // Falling back to a plain generated box if descriptor build
        // fails would crash later anyway; force-try keeps the call
        // sites simple and the failure obvious in development.
        return try! MeshResource.generate(from: [descriptor])
    }

    // MARK: - Cylindrical re-UV

    /// Walks `entity` and every descendant, replacing each
    /// `ModelComponent`'s mesh with a copy whose UVs are computed by
    /// cylindrical projection around the Y axis:
    ///
    ///   u = atan2(z - cz, x - cx) / (2π) + 0.5
    ///   v = (y - minY) / (maxY - minY)
    ///
    /// where `(cx, cz)` is the mesh's bounding-box centre in the X-Z
    /// plane. Positions, normals, and triangle indices are preserved
    /// verbatim — only the texture coordinates change.
    ///
    /// This is the "natural" projection for chess pieces (almost
    /// rotationally symmetric around their Y axis), and produces far
    /// better wood / marble texturing than the random unwraps the
    /// downloaded USDZs ship with.
    static func reUVCylindrical(_ entity: Entity) {
        var stack: [Entity] = [entity]
        while let e = stack.popLast() {
            if var model = e.components[ModelComponent.self] {
                model.mesh = reUVCylindrical(model.mesh)
                e.components.set(model)
            }
            stack.append(contentsOf: e.children)
        }
    }

    /// Cylindrical re-UV of a single `MeshResource`. Returns the
    /// original mesh unchanged on any error path so the caller never
    /// has to deal with optionals.
    private static func reUVCylindrical(_ mesh: MeshResource) -> MeshResource {
        // First pass: gather every vertex from every part to compute a
        // single bounding box. Using the global box (rather than per-
        // part) keeps `v` consistent across multi-part pieces (king's
        // body + crown, knight's head + base, …) so the texture
        // streaks line up across part boundaries.
        var allPositions: [SIMD3<Float>] = []
        for model in mesh.contents.models {
            for part in model.parts {
                allPositions.append(contentsOf: part.positions.elements)
            }
        }
        guard !allPositions.isEmpty else { return mesh }

        let xs = allPositions.map(\.x)
        let ys = allPositions.map(\.y)
        let zs = allPositions.map(\.z)
        let cx = ((xs.min() ?? 0) + (xs.max() ?? 0)) * 0.5
        let cz = ((zs.min() ?? 0) + (zs.max() ?? 0)) * 0.5
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 1
        let yRange = max(maxY - minY, 0.0001)

        var newDescriptors: [MeshDescriptor] = []
        for model in mesh.contents.models {
            for part in model.parts {
                let positions = part.positions.elements
                guard let triangles = part.triangleIndices?.elements else { continue }

                let uvs: [SIMD2<Float>] = positions.map { p in
                    let dx = p.x - cx
                    let dz = p.z - cz
                    let u = atan2(dz, dx) / (2 * .pi) + 0.5
                    let v = (p.y - minY) / yRange
                    return SIMD2<Float>(u, v)
                }

                var descriptor = MeshDescriptor()
                descriptor.positions = MeshBuffer(positions)
                if let normals = part.normals?.elements {
                    descriptor.normals = MeshBuffer(normals)
                }
                descriptor.textureCoordinates = MeshBuffer(uvs)
                descriptor.primitives = .triangles(triangles)
                newDescriptors.append(descriptor)
            }
        }

        guard !newDescriptors.isEmpty,
              let regenerated = try? MeshResource.generate(from: newDescriptors) else {
            return mesh
        }
        return regenerated
    }
}
