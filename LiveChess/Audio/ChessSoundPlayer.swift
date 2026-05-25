import AVFoundation
import Foundation

/// Plays short feedback SFX for in-match events: a piece sliding to a
/// square, a piece being captured, or the moving side delivering check.
///
/// One `AVAudioPlayer` per cue is pre-warmed at init so the first hit
/// doesn't pay the file-load cost mid-game. Calls coming faster than a
/// clip's own duration (e.g. AI moves landing back-to-back during a fast
/// replay) restart the clip via `currentTime = 0`, so the player never
/// silently swallows a cue.
///
/// `category = .ambient, mixWithOthers = true` — the user can keep their
/// own music playing in the background; we layer the SFX on top without
/// ducking or pre-empting it.
@MainActor
final class ChessSoundPlayer {

    static let shared = ChessSoundPlayer()

    enum Cue {
        case move
        case capture
        case check
    }

    private var players: [Cue: AVAudioPlayer] = [:]
    private var sessionConfigured = false

    private init() {
        configureSession()
        preload(.move,    resource: "move")
        preload(.capture, resource: "capture")
        preload(.check,   resource: "check")
    }

    /// Plays the SFX for `cue` if its asset loaded successfully. Silent
    /// no-op otherwise — chess plays fine without sound and we don't
    /// want a missing resource to crash a match.
    func play(_ cue: Cue) {
        guard let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Convenience: pick the right cue from the move + resulting status.
    /// `wasCapture` should be true when the destination square held an
    /// opposing piece before the move OR when the move was en passant.
    /// `status` is the game status produced by applying the move; check
    /// (and checkmate) trump capture/move so the warning lands.
    func play(forMove move: Move, wasCapture: Bool, status: GameStatus) {
        let cue: Cue
        switch status {
        case .check, .checkmate:
            cue = .check
        default:
            cue = wasCapture ? .capture : .move
        }
        play(cue)
    }

    // MARK: - Setup

    private func configureSession() {
        #if !os(macOS)
        // visionOS: configure once so the SFX mix with whatever the
        // user is listening to and respect the silent switch.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionConfigured = true
        } catch {
            sessionConfigured = false
        }
        #endif
    }

    private func preload(_ cue: Cue, resource: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "wav") else {
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[cue] = player
        } catch {
            // Asset missing or unreadable — leave the cue unbound so
            // play(_:) becomes a no-op for it.
        }
    }
}
