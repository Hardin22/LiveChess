import Foundation
import Observation

/// `@MainActor @Observable` holder for the user's piece-style choice.
/// Lives on `AppModel`; consumed by `PieceMeshFactory` at scene-build
/// time and by `PieceCustomizationView` for two-way bindings.
///
/// State is persisted to `UserDefaults` under a single key as JSON, so
/// future schema migrations stay trivial (decode-failure → fall back to
/// `.default`).
@MainActor
@Observable
final class PieceCustomization {

    private static let storageKey = "LiveChess.PieceMaterial.v1"

    /// Current selection. Mutating it persists immediately and triggers
    /// SwiftUI re-renders (Observable). The renderer reads it on the
    /// next scene build — in-flight games keep the materials they
    /// were rendered with, by design (avoids a jarring re-skin during
    /// play).
    var current: PieceMaterial {
        didSet {
            persist(current)
        }
    }

    init() {
        self.current = Self.restore() ?? .default
    }

    /// Snaps `current` to the preset's default colour pair. The
    /// customisation UI calls this when the user taps a different
    /// preset chip — so switching from "Plastic" (white + dark blue)
    /// to "Wood" doesn't carry the plastic colours over to wood
    /// (which usually look terrible). Users can still pick custom
    /// colours afterwards.
    func selectPreset(_ preset: PieceMaterial.Preset) {
        let pair = preset.defaultPair
        current = PieceMaterial(
            preset: preset,
            whiteColor: pair.white,
            blackColor: pair.black
        )
    }

    func resetToDefault() {
        current = .default
    }

    // MARK: - Persistence

    private static func restore() -> PieceMaterial? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PieceMaterial.self, from: data)
    }

    private func persist(_ value: PieceMaterial) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
