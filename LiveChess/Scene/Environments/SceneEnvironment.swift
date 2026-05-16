import Foundation
import RealityKit
import SwiftUI

/// User-selectable backdrop for the immersive chess scene.
///
/// `.ar` keeps Vision Pro passthrough on and uses ARKit plane detection
/// to put the board on a real table. The other cases swap passthrough
/// for a fully-immersive Blender-authored environment with the board
/// pre-seated on the env's table mesh.
enum SceneEnvironment: String, CaseIterable, Identifiable, Sendable {
    case ar
    case dwarvenHall
    case balcony
    case auditoriumStage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ar:           return "AR (your room)"
        case .dwarvenHall:  return "Dwarven Hall"
        case .balcony:      return "Balcony"
        case .auditoriumStage: return "Auditorium Stage"
        }
    }

    var systemImage: String {
        switch self {
        case .ar:           return "arkit"
        case .dwarvenHall:  return "building.columns"
        case .balcony:      return "leaf"
        case .auditoriumStage: return "person.3.sequence.fill"
        }
    }

    /// True for any case that loads a USDZ + needs full immersion.
    var isVirtual: Bool { self != .ar }
}

/// What `EnvironmentScene.mount` returns: the world-space point the
/// chessboard root should be placed at (top of the env's table, lifted
/// a few mm to avoid z-fighting).
struct EnvironmentMount {
    let boardPosition: SIMD3<Float>
}

/// Per-env loader. Each environment owns:
///   * its USDZ filename
///   * the root transform that lands the user "seated" at the board
///   * the table mesh name to read for board placement
///   * any authored lighting / particles tuned to its geometry
///
/// `mount` returns nil on failure so the caller can route to the AR
/// placement fallback — the user always gets a playable board.
@MainActor
protocol EnvironmentScene {
    static func mount(
        into content: any RealityViewContentProtocol
    ) async -> EnvironmentMount?
}

/// Dispatcher used by `ChessSceneView`.
@MainActor
enum EnvironmentLoader {
    static func mount(
        _ env: SceneEnvironment,
        into content: any RealityViewContentProtocol
    ) async -> EnvironmentMount? {
        switch env {
        case .ar:
            return nil
        case .dwarvenHall:
            return await DwarvenHallEnvironment.mount(into: content)
        case .balcony:
            return await BalconyEnvironment.mount(into: content)
        case .auditoriumStage:
            return await AuditoriumStageEnvironment.mount(into: content)
        }
    }
}
