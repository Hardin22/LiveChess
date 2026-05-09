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
            case .gameFinish:
                // Phase 11 folds gameFinish.ratingDiff into the active
                // session here (so the post-game banner can show the
                // Elo delta without a refetch).
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
