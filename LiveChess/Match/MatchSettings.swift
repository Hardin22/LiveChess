import Foundation

/// Settings chosen in the lobby before a match starts.
struct MatchSettings: Hashable, Sendable, Codable {

    enum HumanColor: Hashable, Sendable, Codable, CaseIterable {
        case white
        case black
        case random
    }

    var humanColor: HumanColor
    var aiSettings: AISettings

    init(humanColor: HumanColor = .white, aiSettings: AISettings = AISettings()) {
        self.humanColor = humanColor
        self.aiSettings = aiSettings
    }

    /// Resolves `.random` to a concrete colour.
    func resolvedHumanSide(using rng: () -> Bool = { Bool.random() }) -> Side {
        switch humanColor {
        case .white: return .white
        case .black: return .black
        case .random: return rng() ? .white : .black
        }
    }
}
