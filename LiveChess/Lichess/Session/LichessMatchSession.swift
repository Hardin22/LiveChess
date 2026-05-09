import Foundation
import Observation

/// Per-game runtime for an online Lichess match. Mirrors the role
/// `MatchCoordinator` plays for local games, but the source of truth is
/// the `LichessGameStream` instead of the local AI engine.
///
/// Lifecycle: built from a `gameId` (returned either by
/// `/api/challenge/ai`, by an event-stream `gameStart`, or by an entry
/// in `/api/account/playing`), then `start()`ed. The actor opens its
/// game stream and consumes frames:
///
///   * `gameFull` — first frame and re-emitted on reconnect. Treated as
///     authoritative: clear the `Match`, replay every UCI in
///     `state.moves` through the local rules engine, refresh clocks +
///     opponent + status.
///   * `gameState` — incremental update. Diff against the move count
///     we've already applied; play the missing UCIs through rules. If
///     the count goes DOWN (takeback accepted by both sides), reset and
///     replay from the start position.
///   * `opponentGone` — set/clear the gone-info; UI surfaces a
///     claim-victory countdown.
///   * `chatLine` — ignored in v1 (chat off).
///
/// The drag handler talks to this session through the shared
/// `MatchSession` protocol; Lichess-specific actions
/// (resign / abort / draw / takeback / claim-victory) live as direct
/// methods and are wired up in the next phase.
@MainActor
@Observable
final class LichessMatchSession: MatchSession {

    enum ConnectionState: Sendable, Equatable {
        case connecting
        case live
        case reconnecting(attempt: Int)
        case ended
    }

    /// Snapshot of the live wall-time clocks. Values are *as last reported
    /// by the server* — UI tickdowns happen client-side via a Timer.
    struct ClockState: Sendable, Equatable {
        var whiteMillis: Int
        var blackMillis: Int
        let whiteIncrementMillis: Int
        let blackIncrementMillis: Int
    }

    struct Opponent: Sendable, Equatable {
        let username: String
        let title: String?
        let rating: Int?
        let provisional: Bool
        /// Set iff opponent is Stockfish-on-Lichess; carries the level 1–8.
        let aiLevel: Int?
    }

    struct Result: Sendable, Equatable {
        let status: LichessStatus
        /// `nil` for draws / aborts.
        let winner: LichessColor?
        /// Signed Elo delta from the gameFinish event. nil for unrated /
        /// AI games (which Lichess always reports unrated).
        let ratingDiff: Int?
    }

    let gameID: String
    let humanColor: Side
    let opponent: Opponent
    let isRated: Bool
    let initialFen: String

    /// Domain match — fed by `apply(gameFull:)` / `apply(gameState:)`.
    private(set) var match: Match
    private(set) var clock: ClockState
    private(set) var connection: ConnectionState = .connecting
    /// Set when the opponent has offered a draw and is waiting on us.
    private(set) var pendingDrawOfferFromOpponent: Bool = false
    /// Set when WE have offered a draw and the opponent hasn't responded.
    private(set) var pendingDrawOfferFromUs: Bool = false
    private(set) var pendingTakebackOfferFromOpponent: Bool = false
    private(set) var pendingTakebackOfferFromUs: Bool = false
    private(set) var opponentGoneClaimWinInSeconds: Int?
    /// `nil` while the game is in progress; populated when a terminal
    /// gameState arrives. The HUD shows the game-over banner from this.
    private(set) var result: Result?

    /// Called on the main actor every time a move is applied to `match`
    /// from a stream frame (server-confirmed) or from the user's optimistic
    /// local apply. The scene host uses this to animate the piece.
    @ObservationIgnored
    var moveAppliedHandler: (@MainActor (Move) -> Void)?

    /// Called when `gameFull` arrives and forces a board reset (cold start
    /// or reconnect-replay). The scene host uses this to wipe and re-seed
    /// the board's piece entities from scratch.
    @ObservationIgnored
    var matchResetHandler: (@MainActor () -> Void)?

    private let api: LichessAPIClient
    private let stream: LichessGameStream
    private let rules: any RulesEngine
    private var consumerTask: Task<Void, Never>?

    init(
        gameID: String,
        humanColor: Side,
        opponent: Opponent,
        isRated: Bool,
        initialFen: String,
        clock: ClockState,
        api: LichessAPIClient,
        stream: LichessGameStream,
        rules: any RulesEngine
    ) {
        self.gameID = gameID
        self.humanColor = humanColor
        self.opponent = opponent
        self.isRated = isRated
        self.initialFen = initialFen
        self.clock = clock
        self.api = api
        self.stream = stream
        self.rules = rules
        let start = Self.startPosition(fromFen: initialFen)
        self.match = Match(startPosition: start)
    }

    // MARK: - MatchSession

    var isHumanTurn: Bool {
        guard result == nil else { return false }
        guard !match.status.isGameOver else { return false }
        guard connection == .live else { return false }
        return match.currentPosition.sideToMove == humanColor
    }

    func legalMoves(from square: Square) -> [Move] {
        rules.legalMoves(from: square, in: match.currentPosition)
    }

    /// Optimistic local apply + POST to the Board API. On a 4xx server
    /// rejection (illegal, out-of-turn, game ended, …) the local apply
    /// is rolled back and the renderer is asked to re-seed from the
    /// pre-move snapshot via `matchResetHandler`. The next `gameState`
    /// frame from the stream will confirm-or-correct in any case, so
    /// even a swallowed error doesn't leave us out of sync for long.
    func submitMove(_ move: Move) async {
        guard isHumanTurn else { return }

        // Optimistic local apply through the rules engine.
        let preStatus = match.status
        let nextPosition: Position
        do {
            nextPosition = try rules.apply(move, to: match.currentPosition)
        } catch {
            // Locally illegal — the drag handler shouldn't allow this; bail
            // without reaching the network.
            return
        }
        let nextStatus = rules.status(
            of: nextPosition,
            history: match.positions + [nextPosition]
        )
        match.apply(move: move, resulting: nextPosition, status: nextStatus)
        moveAppliedHandler?(move)

        // POST. Errors → rollback.
        do {
            try await api.makeMove(gameID: gameID, uci: move.uci)
        } catch {
            match.rollbackLastMove(restoringStatus: preStatus)
            matchResetHandler?()
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Surface for the most recent action error (move, resign, draw, …)
    /// so the HUD can show a transient toast / banner. Cleared by
    /// `clearLastError()` once the user has dismissed the message.
    private(set) var lastError: LichessError?

    func clearLastError() {
        lastError = nil
    }

    // MARK: - Board API actions

    /// Resigns the game. Server marks status `resign` with the opponent
    /// as `winner`; the resulting `gameState` frame populates `result`.
    func resign() async {
        guard result == nil else { return }
        do {
            try await api.resign(gameID: gameID)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Aborts the game — only valid before either side has made a move.
    /// Lichess returns 400 otherwise; UI hides this affordance once
    /// `match.moves.count > 0`.
    func abort() async {
        guard result == nil else { return }
        do {
            try await api.abort(gameID: gameID)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Offers a draw if the opponent isn't already offering one;
    /// accepts otherwise (the API endpoint is the same `/draw/yes`
    /// either way — Lichess decides based on the in-flight state).
    /// `pendingDrawOfferFromUs` flips on after the next gameState
    /// confirms.
    func offerOrAcceptDraw() async {
        guard result == nil else { return }
        do {
            try await api.draw(gameID: gameID, accept: true)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Declines an outstanding draw offer from the opponent. No-op (or
    /// 400) if there's no offer to decline; UI gates the affordance on
    /// `pendingDrawOfferFromOpponent == true`.
    func declineDraw() async {
        guard result == nil else { return }
        do {
            try await api.draw(gameID: gameID, accept: false)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Same offer/accept/decline shape as draws but for takebacks.
    /// Accepting an opponent's takeback rolls the game back one (or
    /// two, depending on whose turn it is) ply server-side; the
    /// resulting `gameState` carries fewer moves than we have locally
    /// and we replay from start in `apply(gameState:)`.
    func offerOrAcceptTakeback() async {
        guard result == nil else { return }
        do {
            try await api.takeback(gameID: gameID, accept: true)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    func declineTakeback() async {
        guard result == nil else { return }
        do {
            try await api.takeback(gameID: gameID, accept: false)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Claims victory after the opponent has been disconnected long
    /// enough — only valid when `opponentGoneClaimWinInSeconds` has
    /// counted down to 0. Server returns 400 otherwise; UI gates the
    /// affordance on the countdown value.
    func claimVictory() async {
        guard result == nil else { return }
        do {
            try await api.claimVictory(gameID: gameID)
        } catch {
            lastError = error as? LichessError ?? .network(underlying: error)
        }
    }

    /// Whether the abort affordance should be visible. Lichess only
    /// allows abort before the first move from either side.
    var canAbort: Bool {
        result == nil && match.moves.isEmpty
    }

    /// Whether the claim-victory button should be enabled (countdown
    /// elapsed AND a gone-info is in flight).
    var canClaimVictory: Bool {
        result == nil
            && opponentGoneClaimWinInSeconds == 0
    }

    // MARK: - Lifecycle

    /// Begins the game stream and starts consuming events. Idempotent.
    func start() async {
        guard consumerTask == nil else { return }
        await stream.start()
        consumerTask = Task { [weak self] in
            await self?.consume()
        }
    }

    /// Tears down the stream + consumer task. Idempotent.
    func disconnect() async {
        await stream.stop()
        consumerTask?.cancel()
        consumerTask = nil
        connection = .ended
    }

    // MARK: - Stream consumption

    private func consume() async {
        for await event in stream.updates {
            if Task.isCancelled { return }
            switch event {
            case .gameFull(let full):
                apply(gameFull: full)
            case .gameState(let state):
                apply(gameState: state)
            case .opponentGone(let gone):
                apply(opponentGone: gone)
            case .chatLine:
                break  // v1: chat off
            case .unknown:
                break  // forward-compat: ignore unknown event types
            }
            connection = .live
        }
        // Stream finished — server-side closure or stop(). If the game
        // isn't already marked finished, surface as ended so the UI can
        // offer a "back to lobby" affordance.
        if result == nil {
            connection = .ended
        }
    }

    /// Authoritative replay: reset the match to `initialFen` and play
    /// every UCI in `state.moves` through the local rules engine.
    /// Re-applied on every `gameFull` (initial frame + reconnect re-emit).
    private func apply(gameFull: LichessGameFull) {
        let start = Self.startPosition(fromFen: gameFull.initialFen)
        match.reset(to: start)
        matchResetHandler?()
        applyMoves(in: gameFull.state.moves)
        applyClock(from: gameFull.state)
        applyStatus(from: gameFull.state)
        applyOfferFlags(from: gameFull.state)
    }

    /// Incremental: figure out what's new in `state.moves` versus what
    /// we've already applied, and play the diff. Handles takebacks by
    /// resetting and replaying when the new move count is *less* than
    /// what we've already applied.
    private func apply(gameState: LichessGameState) {
        let serverMoves = Self.parseMoves(gameState.moves)
        if serverMoves.count < match.moves.count {
            // Takeback (or any other state rewind). Replay from start.
            let start = Self.startPosition(fromFen: initialFen)
            match.reset(to: start)
            matchResetHandler?()
            applyMoves(in: gameState.moves)
        } else {
            let alreadyApplied = match.moves.count
            let newOnes = serverMoves.dropFirst(alreadyApplied)
            for uci in newOnes {
                applyOneMove(uci: uci)
            }
        }
        applyClock(from: gameState)
        applyStatus(from: gameState)
        applyOfferFlags(from: gameState)
    }

    private func apply(opponentGone: LichessOpponentGone) {
        opponentGoneClaimWinInSeconds = opponentGone.gone
            ? opponentGone.claimWinInSeconds
            : nil
    }

    // MARK: - Frame helpers

    private func applyMoves(in spaceSeparated: String) {
        let uciList = Self.parseMoves(spaceSeparated)
        for uci in uciList {
            applyOneMove(uci: uci)
        }
    }

    private func applyOneMove(uci: String) {
        guard let move = Move(uci: uci) else { return }
        do {
            let next = try rules.apply(move, to: match.currentPosition)
            let status = rules.status(of: next, history: match.positions + [next])
            match.apply(move: move, resulting: next, status: status)
            moveAppliedHandler?(move)
        } catch {
            // Hitting this means our rules engine disagrees with Lichess'
            // — should never happen for standard chess. We swallow rather
            // than crash, so the user can still see the partial board;
            // the next gameFull on reconnect will resync.
        }
    }

    private func applyClock(from state: LichessGameState) {
        clock = ClockState(
            whiteMillis: state.wtime,
            blackMillis: state.btime,
            whiteIncrementMillis: state.winc,
            blackIncrementMillis: state.binc
        )
    }

    private func applyStatus(from state: LichessGameState) {
        guard state.status.isFinished else {
            result = nil
            return
        }
        result = Result(
            status: state.status,
            winner: state.winner,
            // ratingDiff arrives via /api/stream/event's gameFinish event,
            // not on the game-stream's gameState. Consumer of this session
            // sets it via `applyRatingDiff(_:)` below when that event lands.
            ratingDiff: result?.ratingDiff
        )
    }

    private func applyOfferFlags(from state: LichessGameState) {
        let myFlag = humanColor == .white ? state.wdraw : state.bdraw
        let theirFlag = humanColor == .white ? state.bdraw : state.wdraw
        pendingDrawOfferFromUs = myFlag ?? false
        pendingDrawOfferFromOpponent = theirFlag ?? false

        let myTakeback = humanColor == .white ? state.wtakeback : state.btakeback
        let theirTakeback = humanColor == .white ? state.btakeback : state.wtakeback
        pendingTakebackOfferFromUs = myTakeback ?? false
        pendingTakebackOfferFromOpponent = theirTakeback ?? false
    }

    /// Called by the lobby observer when the global `gameFinish` event
    /// arrives carrying `ratingDiff`. Merges into the existing result.
    func applyRatingDiff(_ diff: Int?) {
        guard var current = result else { return }
        current = Result(
            status: current.status,
            winner: current.winner,
            ratingDiff: diff
        )
        result = current
    }

    // MARK: - Static helpers

    private static func parseMoves(_ spaceSeparated: String) -> [String] {
        spaceSeparated
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Lichess sends `"startpos"` as a sentinel for "the standard initial
    /// position". Our domain model expects an actual `Position`, so we
    /// dispatch on the sentinel; otherwise we parse the FEN.
    private static func startPosition(fromFen fen: String) -> Position {
        if fen == "startpos" || fen.isEmpty {
            return .standardStart
        }
        return Position(fen: fen) ?? .standardStart
    }
}

extension LichessMatchSession {
    /// Deep link back to the game on lichess.org, oriented to the user's
    /// played colour. Used by the post-game "Analizza su Lichess" button.
    var analysisURL: URL {
        let suffix = humanColor == .white ? "white" : "black"
        return URL(string: "https://lichess.org/\(gameID)/\(suffix)")!
    }
}
