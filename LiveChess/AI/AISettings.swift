import Foundation

/// User-tunable parameters for an AI opponent.
///
/// `skillLevel` is the UCI Skill Level (`0…20`) supported by Stockfish and
/// most modern UCI engines. `thinkingTime` upper-bounds the time the engine
/// spends per move (sent as `go movetime <ms>` in UCI).
struct AISettings: Hashable, Sendable, Codable {

    static let minSkillLevel = 0
    static let maxSkillLevel = 20

    var skillLevel: Int
    var thinkingTime: Duration

    init(skillLevel: Int = 10, thinkingTime: Duration = .seconds(1)) {
        self.skillLevel = max(Self.minSkillLevel, min(Self.maxSkillLevel, skillLevel))
        self.thinkingTime = thinkingTime
    }
}
