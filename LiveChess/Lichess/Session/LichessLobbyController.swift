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

    /// Challenges received from other Lichess users while this session
    /// is active. The lobby UI shows each as a banner with Accept /
    /// Decline buttons. Populated by `challenge` events on the global
    /// stream; entries removed on `challengeCanceled` /
    /// `challengeDeclined` (and on a successful local accept/decline).
    private(set) var incomingChallenges: [LichessChallenge] = []

    /// Games already in progress for the signed-in user. Refreshed via
    /// `refreshActiveGames()` on lobby appearance + after every event-
    /// stream reconnect (Lichess does not replay missed events, so a
    /// missed `gameStart` would otherwise leave us blind to a game
    /// started while we were offline).
    private(set) var activeGames: [LichessPlayingGame] = []

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

    /// In-flight seek task (Quick Pair). Cancellation closes the HTTP
    /// connection client-side, which removes us from the pool
    /// server-side.
    private var seekTask: Task<Void, Never>?

    /// In-flight friend-challenge ID (so we can cancel it via
    /// `/api/challenge/{id}/cancel` if the user backs out before the
    /// recipient accepts).
    private var pendingFriendChallengeID: String?

    /// Last requested time control — stashed so the matchmaking branch
    /// (Quick Pair → gameStart) can pre-populate the resulting
    /// `LichessMatchSession` clock with the right initial values
    /// instead of zero-zero, avoiding a brief 00:00 flash before
    /// `gameFull` arrives.
    private var lastRequestedTimeControl: LichessTimeControlSpec?

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
        // Reconnect → re-fetch active games. Lichess does not replay
        // missed events across the gap, so a game started while we
        // were offline would otherwise be invisible until the user
        // navigates somewhere.
        Task { [weak self] in
            await stream.setReconnectHandler { [weak self] in
                await self?.refreshActiveGames()
            }
            await stream.setAuthFailureHandler { [weak self] in
                await self?.handleAuthFailure()
            }
            _ = self  // silence unused-capture warning
        }
        eventStream = stream
        eventStreamConsumer = Task { [weak self] in
            await stream.start()
            await self?.consumeEvents(stream)
        }
    }

    /// Fired by either stream when Lichess rejects the bearer with 401.
    /// Wipes local state via `signOut(local-only)` so the lobby's
    /// `lichessCard` returns to the sign-in CTA.
    private func handleAuthFailure() async {
        // Tear down our streams first so the session.signOut() doesn't
        // race with our reconnect loops.
        await stopEventStream()
        cancelSeek()
        // Wipe locally — the bearer is dead so the server-side revoke
        // would 401 anyway; signOut() best-efforts that.
        await session.signOut()
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
            let stream = makeGameStream(gameID: game.id, token: token)
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

    /// Enters the matchmaking pool (`POST /api/board/seek`) with the
    /// given criteria. The HTTP connection is held open server-side
    /// until a partner is matched (a `gameStart` event then arrives on
    /// `/api/stream/event` and lights up an online session) — or the
    /// user cancels with `cancelSeek()`, which tears down the
    /// connection and removes us from the pool.
    func quickPair(
        rated: Bool,
        timeControl: LichessTimeControlSpec
    ) {
        guard let _ = session.token else {
            lastError = .notAuthenticated
            return
        }
        guard seekTask == nil else { return }

        let label = Self.label(for: timeControl)
        pendingAction = .seeking(rated: rated, label: label)
        lastError = nil
        lastRequestedTimeControl = timeControl

        let api = session.api
        seekTask = Task { [weak self] in
            do {
                try await api.runSeek(timeControl: timeControl, rated: rated)
            } catch let error as LichessError {
                self?.handleSeekFailure(error)
                return
            } catch is CancellationError {
                // User cancelled — quietly clear pending state.
                self?.clearSeekPending()
                return
            } catch {
                self?.handleSeekFailure(.network(underlying: error))
                return
            }
            // Server closed the connection — partner found. The
            // gameStart event lands on the global stream; nothing else
            // to do here.
            self?.clearSeekPending()
        }
    }

    /// Cancels an in-flight seek. No-op if there isn't one.
    func cancelSeek() {
        seekTask?.cancel()
        seekTask = nil
        pendingAction = nil
        lastRequestedTimeControl = nil
    }

    /// Sends a direct challenge to a specific Lichess user. Returns
    /// once the challenge is *created* (status `created`); the
    /// resulting `gameStart` arrives on the event stream when the
    /// recipient accepts.
    func challengeFriend(
        username: String,
        rated: Bool,
        timeControl: LichessTimeControlSpec,
        color: LichessChallengeColor
    ) async {
        guard let _ = session.token else {
            lastError = .notAuthenticated
            return
        }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingAction = .creatingUserChallenge(username: trimmed)
        lastError = nil
        lastRequestedTimeControl = timeControl
        do {
            let challenge = try await session.api.createUserChallenge(
                username: trimmed,
                rated: rated,
                timeControl: timeControl,
                color: color
            )
            pendingFriendChallengeID = challenge.id
            pendingAction = .waitingForOpponent(challengeID: challenge.id)
        } catch let error as LichessError {
            pendingAction = nil
            lastError = error
        } catch {
            pendingAction = nil
            lastError = .network(underlying: error)
        }
    }

    /// Cancels an outstanding friend-challenge POST that hasn't been
    /// accepted yet. No-op if there isn't one.
    func cancelFriendChallenge() async {
        guard let id = pendingFriendChallengeID else { return }
        pendingFriendChallengeID = nil
        pendingAction = nil
        try? await session.api.cancelChallenge(id)
    }

    /// Accepts an incoming challenge from another user. Server then
    /// emits a `gameStart` on the global stream, which spins up an
    /// online match session normally.
    func acceptIncoming(_ id: String) async {
        do {
            try await session.api.acceptChallenge(id)
            incomingChallenges.removeAll { $0.id == id }
        } catch let error as LichessError {
            lastError = error
        } catch {
            lastError = .network(underlying: error)
        }
    }

    /// Declines an incoming challenge with an optional reason. The
    /// reason is shown to the challenger as context; `nil` falls back
    /// to Lichess' "generic" decline message.
    func declineIncoming(_ id: String, reason: LichessDeclineReason? = nil) async {
        do {
            try await session.api.declineChallenge(id, reason: reason)
            incomingChallenges.removeAll { $0.id == id }
        } catch let error as LichessError {
            lastError = error
        } catch {
            lastError = .network(underlying: error)
        }
    }

    /// Pulls the current `nowPlaying` list. Called on lobby appear and
    /// after event-stream reconnects (where missed `gameStart` events
    /// would otherwise leave the active list stale).
    func refreshActiveGames() async {
        do {
            activeGames = try await session.api.accountPlaying()
        } catch let error as LichessError {
            lastError = error
        } catch {
            lastError = .network(underlying: error)
        }
    }

    /// Resumes an in-progress game by opening its game stream and
    /// surfacing the resulting `LichessMatchSession`. Driven by tap on
    /// the "Partite in corso" list.
    func resumeActiveGame(_ playing: LichessPlayingGame) {
        guard let token = session.token else { return }

        let humanColor: Side = playing.color == .white ? .white : .black
        let opponent = LichessMatchSession.Opponent(
            username: playing.opponent.username,
            title: playing.opponent.title,
            rating: playing.opponent.rating,
            provisional: false,
            aiLevel: playing.opponent.aiLevel
        )
        // We don't have ms-precision clock numbers here — `secondsLeft`
        // is the only available figure. Fill both clocks with it as a
        // first approximation; `gameFull` overwrites within
        // milliseconds of the stream opening.
        let initialMs = (playing.secondsLeft ?? 0) * 1000
        let initialClock = LichessMatchSession.ClockState(
            whiteMillis: initialMs,
            blackMillis: initialMs,
            whiteIncrementMillis: 0,
            blackIncrementMillis: 0
        )
        let stream = LichessGameStream(gameID: playing.gameId, token: token)
        let matchSession = LichessMatchSession(
            gameID: playing.gameId,
            humanColor: humanColor,
            opponent: opponent,
            isRated: playing.rated,
            initialFen: playing.fen,
            clock: initialClock,
            api: session.api,
            stream: stream,
            rules: rules
        )
        onGameSessionReady?(matchSession)
    }

    private func handleSeekFailure(_ error: LichessError) {
        seekTask = nil
        pendingAction = nil
        lastError = error
    }

    private func clearSeekPending() {
        seekTask = nil
        pendingAction = nil
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
            case .gameStart(let info):
                handleGameStart(info)
            case .gameFinish(let info):
                handleGameFinish(info)
            case .challenge(let challenge):
                // Lichess sometimes re-sends an existing challenge
                // (e.g. after reconnect) — dedupe by id.
                incomingChallenges.removeAll { $0.id == challenge.id }
                incomingChallenges.append(challenge)
            case .challengeCanceled(let challenge),
                 .challengeDeclined(let challenge):
                incomingChallenges.removeAll { $0.id == challenge.id }
            case .unknown:
                break
            }
        }
    }

    /// `gameFinish` event handler. If the event refers to the *currently
    /// active* match session, fold the ratingDiff into its result so the
    /// post-game banner can show the Elo delta. The match-stream's
    /// terminal `gameState` set the rest of the result fields already.
    private func handleGameFinish(_ info: LichessGameEventInfo) {
        // The lobby host (LobbyView / scene host) is responsible for
        // wiring `currentMatchSession` so the ratingDiff can be routed.
        // For now we surface via `onGameFinishReceived` so listeners
        // can opt in.
        onGameFinishReceived?(info)
    }

    /// Fired on the main actor when a `gameFinish` event arrives. Set
    /// by the scene host so the active `LichessMatchSession` can fold
    /// `ratingDiff` into its result.
    @ObservationIgnored
    var onGameFinishReceived: (@MainActor (LichessGameEventInfo) -> Void)?

    /// Builds and surfaces a `LichessMatchSession` for a freshly-started
    /// online game. Used for both Quick Pair (after `runSeek` matched)
    /// and accepted friend challenges. AI challenges skip this path —
    /// they get the game id directly from the REST response and build
    /// their session inline in `challengeAI(...)`.
    private func handleGameStart(_ info: LichessGameEventInfo) {
        guard let token = session.token else { return }

        // The pending action was either a seek or a waiting-for-opponent.
        // Either way we're done with it — clear so the lobby UI returns
        // to its idle state.
        seekTask = nil
        pendingFriendChallengeID = nil
        pendingAction = nil

        let humanColor: Side = info.color == .white ? .white : .black
        let opponent = LichessMatchSession.Opponent(
            username: info.opponent.username,
            title: info.opponent.title,
            rating: info.opponent.rating,
            provisional: false,
            aiLevel: info.opponent.aiLevel
        )

        // Seed clock from the time-control we requested if we have one;
        // gameFull will overwrite within milliseconds anyway. Using
        // a sane initial value avoids a brief 00:00 flash in the HUD.
        let initialClock = lastRequestedTimeControl
            .map { Self.initialClock(for: $0) }
            ?? LichessMatchSession.ClockState(
                whiteMillis: 0,
                blackMillis: 0,
                whiteIncrementMillis: 0,
                blackIncrementMillis: 0
            )

        let stream = LichessGameStream(gameID: info.gameId, token: token)
        let matchSession = LichessMatchSession(
            gameID: info.gameId,
            humanColor: humanColor,
            opponent: opponent,
            isRated: info.rated,
            initialFen: info.fen ?? "startpos",
            clock: initialClock,
            api: session.api,
            stream: stream,
            rules: rules
        )
        onGameSessionReady?(matchSession)
    }

    /// Builds a per-game stream and wires the auth-failure handler. Used
    /// by all three game-creation paths (AI challenge, gameStart from
    /// event-stream, resumeActiveGame).
    private func makeGameStream(gameID: String, token: String) -> LichessGameStream {
        let stream = LichessGameStream(gameID: gameID, token: token)
        Task { [weak self] in
            // Inner closure also captures `self` weakly so the handler
            // closure (stored on the actor and invoked from arbitrary
            // concurrent contexts) doesn't outlive the controller.
            await stream.setAuthFailureHandler { [weak self] in
                await self?.handleAuthFailure()
            }
        }
        return stream
    }

    private static func label(for spec: LichessTimeControlSpec) -> String {
        switch spec {
        case let .realTime(limit, increment):
            let minutes = limit / 60
            return "\(minutes)+\(increment)"
        case let .correspondence(daysPerTurn):
            return "Corrispondenza (\(daysPerTurn)g)"
        case .unlimited:
            return "Senza tempo"
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
