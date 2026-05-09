import Foundation
import Observation

/// Owns the lobby-side Lichess flows: issuing challenges, listening to the
/// global event stream for incoming challenges + game starts, and
/// constructing per-game `LichessMatchSession` instances when a game is
/// ready to render.
///
/// Phase-7 surface is intentionally narrow — only `challengeAI(...)` is
/// wired. Quick-pair seeks (`/api/board/seek`) and friend challenges
/// (`/api/challenge/{user}`) land in phase 9; incoming-challenge handling
/// + active-games listing land in phase 10. The event-stream consumer
/// loop is ready though, so phase 9/10 only need to add new dispatch
/// branches.
@MainActor
@Observable
final class LichessLobbyController {

    enum PendingAction: Sendable, Equatable {
        case creatingAIChallenge(level: Int)
        case creatingUserChallenge(username: String)
        case waitingForOpponent(challengeID: String)
        case seeking(rated: Bool, label: String)
    }

    private(set) var pendingAction: PendingAction?
    private(set) var lastError: LichessError?

    /// Fired on the main actor when a fully-constructed
    /// `LichessMatchSession` is ready to be rendered. The lobby host
    /// (typically `LobbyView`) sets `appModel.activeSession = .online(session)`
    /// and triggers `OpenImmersiveSpaceAction`.
    @ObservationIgnored
    var onGameSessionReady: (@MainActor (LichessMatchSession) -> Void)?

    let session: LichessSession
    private let rules: any RulesEngine

    /// Lazily built event stream — created the first time we have a
    /// token. Re-created on token rotation so the new bearer is used.
    private var eventStream: LichessEventStream?
    private var eventStreamConsumer: Task<Void, Never>?

    init(
        session: LichessSession,
        rules: any RulesEngine = ChessKitRulesEngine()
    ) {
        self.session = session
        self.rules = rules
    }

    /// Boot the event-stream consumer if we have a token and aren't
    /// already running. Idempotent.
    func startEventStreamIfNeeded() {
        guard let token = session.token else { return }
        guard eventStream == nil else { return }
        let stream = LichessEventStream(token: token)
        eventStream = stream
        eventStreamConsumer = Task { [weak self] in
            await stream.start()
            await self?.consumeEvents(stream)
        }
    }

    func stopEventStream() async {
        if let stream = eventStream {
            await stream.stop()
        }
        eventStreamConsumer?.cancel()
        eventStreamConsumer = nil
        eventStream = nil
    }

    /// Issues an AI challenge against Lichess' hosted Stockfish at the
    /// requested level (1–8) + time control. Always unrated — Lichess
    /// hardcodes that server-side. On success the session is wired up
    /// and surfaced via `onGameSessionReady`; the lobby host opens the
    /// immersive space.
    func challengeAI(
        level: Int,
        timeControl: LichessTimeControlSpec,
        color: LichessChallengeColor = .white
    ) async {
        guard let token = session.token else {
            lastError = .notAuthenticated
            return
        }
        pendingAction = .creatingAIChallenge(level: level)
        lastError = nil
        do {
            let game = try await session.api.createAIChallenge(
                level: level,
                timeControl: timeControl,
                color: color
            )
            let humanColor: Side = (game.player == "black") ? .black : .white
            let opponent = LichessMatchSession.Opponent(
                username: "Stockfish",
                title: nil,
                rating: nil,
                provisional: false,
                aiLevel: level
            )
            let initialClock = Self.initialClock(for: timeControl)
            let stream = LichessGameStream(gameID: game.id, token: token)
            let matchSession = LichessMatchSession(
                gameID: game.id,
                humanColor: humanColor,
                opponent: opponent,
                isRated: false,
                initialFen: game.fen ?? "startpos",
                clock: initialClock,
                api: session.api,
                stream: stream,
                rules: rules
            )
            pendingAction = nil
            onGameSessionReady?(matchSession)
        } catch let error as LichessError {
            pendingAction = nil
            lastError = error
        } catch {
            pendingAction = nil
            lastError = .network(underlying: error)
        }
    }

    // MARK: - Event stream consumption

    /// Long-running loop that dispatches the global event-stream payloads
    /// to the right place: in v1 we mostly just need `gameStart` to spin
    /// up a `LichessMatchSession` for human-vs-human challenges; phase 10
    /// adds incoming-challenge handling and game-finish rating-diff
    /// folding.
    private func consumeEvents(_ stream: LichessEventStream) async {
        for await event in stream.events {
            if Task.isCancelled { return }
            switch event {
            case .gameStart:
                // Phase 9 (Quick Pair + friend challenge) wires this:
                // build a LichessMatchSession from the GameEventInfo
                // payload and call onGameSessionReady. AI games skip
                // the event stream entirely (we got the game id from
                // the REST response), so this branch is dormant in
                // phase 7.
                break
            case .gameFinish:
                // Phase 11 wires the rating-diff fold-in here.
                break
            case .challenge:
                // Phase 10 wires the incoming-challenge banner here.
                break
            case .challengeCanceled, .challengeDeclined:
                break
            case .unknown:
                break
            }
        }
    }

    // MARK: - Helpers

    /// Builds the initial `ClockState` from the chosen time control. For
    /// real-time games the limit is in seconds → milliseconds; for
    /// correspondence we fake an effectively-infinite clock so the HUD's
    /// countdown doesn't show a hard zero (Lichess won't time us out for
    /// a daily game in the way the wall-time clock would suggest).
    private static func initialClock(
        for spec: LichessTimeControlSpec
    ) -> LichessMatchSession.ClockState {
        switch spec {
        case let .realTime(limit, increment):
            let ms = limit * 1000
            let incMs = increment * 1000
            return LichessMatchSession.ClockState(
                whiteMillis: ms,
                blackMillis: ms,
                whiteIncrementMillis: incMs,
                blackIncrementMillis: incMs
            )
        case .correspondence, .unlimited:
            return LichessMatchSession.ClockState(
                whiteMillis: Int.max,
                blackMillis: Int.max,
                whiteIncrementMillis: 0,
                blackIncrementMillis: 0
            )
        }
    }
}
