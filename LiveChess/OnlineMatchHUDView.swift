import SwiftUI
import Combine

/// Floating HUD for an online Lichess match. Mirrors the local HUD's
/// glass aesthetic and Italian copy, but specialises the content for the
/// online flow:
///
///   * Opponent header (title + username + rating, with a live
///     connection dot).
///   * Server-driven clock, ticked down per second client-side from the
///     last reported `wtime`/`btime`.
///   * Move counter + last move (UCI).
///   * Resign / Abort buttons (full action set lands in phase 8).
///   * Game-over banner (rating delta + Lichess analysis link arrive in
///     phase 11).
///   * "Torna alla lobby" button that disconnects the session and
///     dismisses the immersive space.
@MainActor
struct OnlineMatchHUDView: View {

    @Bindable var session: LichessMatchSession
    /// Optional — drives the "Move board" button. Nil only in the
    /// SwiftUI preview; in real scenes the placement controller is
    /// always set up by `ChessSceneView.make`.
    var placement: PlacementController?

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var appModel

    @State private var now: Date = .now
    /// 10 Hz so the active player's clock visibly counts down without
    /// looking choppy when the time control gets short. The 100 ms
    /// granularity matches what lichess.org displays at low time.
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            opponentHeader
            Divider()
            clockSection
            Divider()
            statusSection
            if session.pendingDrawOfferFromOpponent {
                drawOfferBanner
            }
            if session.pendingTakebackOfferFromOpponent {
                takebackOfferBanner
            }
            if !session.match.moves.isEmpty {
                Divider()
                moveLog
            }
            if session.result != nil {
                Divider()
                gameOverSection
            }
            Divider()
            controls
            if let error = session.lastError {
                errorBanner(error)
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .topLeading)
        .glassBackgroundEffect()
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Offer banners

    private var drawOfferBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                Text("\(opponentName) offers a draw")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Accept") {
                    Task { await session.offerOrAcceptDraw() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Decline") {
                    Task { await session.declineDraw() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var takebackOfferBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                Text("\(opponentName) requests a takeback")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Accept") {
                    Task { await session.offerOrAcceptTakeback() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Decline") {
                    Task { await session.declineTakeback() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorBanner(_ error: LichessError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(humanReadable(error))
                .font(.caption)
            Spacer()
            Button {
                session.clearLastError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .foregroundStyle(.red)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func humanReadable(_ error: LichessError) -> String {
        switch error {
        case .notAuthenticated: return "Not signed in."
        case .tokenExpired: return "Session expired — back to lobby to sign in again."
        case .scopeInsufficient: return "Insufficient Lichess permissions."
        case .rateLimited: return "Lichess is rate-limiting — try again in a minute."
        case .clientError: return "Move rejected by Lichess."
        case .serverError: return "Lichess is not responding right now."
        case .decoding: return "Unrecognized response."
        case .network: return "Lost connection to Lichess."
        case .invalidResponse: return "Invalid Lichess response."
        }
    }

    // MARK: - Sections

    private var opponentHeader: some View {
        HStack(spacing: 10) {
            opponentDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let title = session.opponent.title {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    Text(opponentName)
                        .font(.callout.weight(.medium))
                }
                if let rating = session.opponent.rating {
                    Text("\(rating) \(session.isRated ? "rated" : "casual")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            connectionDot
        }
    }

    private var clockSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("White")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(format(milliseconds: displayedMillis(forSide: .white)))
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(highlightWhite ? .primary : .secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Black")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(format(milliseconds: displayedMillis(forSide: .black)))
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(highlightBlack ? .primary : .secondary)
            }
        }
    }

    /// Computes the displayed clock for `side`. The side-to-move's clock
    /// ticks down between server frames; the opponent's stays at the
    /// last reported value. Server frames (`gameFull` / `gameState`)
    /// reset the anchor so we never drift more than ~1 RTT off the
    /// authoritative server time.
    private func displayedMillis(forSide side: Side) -> Int {
        let baseMs = side == .white
            ? session.clock.whiteMillis
            : session.clock.blackMillis

        // Don't tick on game-over or while the corresponding side isn't
        // on move. Also short-circuit on absurdly large clocks (we use
        // Int.max as a sentinel for unlimited / correspondence).
        guard session.result == nil,
              session.match.currentPosition.sideToMove == side,
              baseMs < Int.max / 2
        else { return baseMs }

        let elapsedMs = Int(now.timeIntervalSince(session.lastClockUpdate) * 1000)
        return max(0, baseMs - elapsedMs)
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 10) {
            sideDot(session.match.currentPosition.sideToMove)
            VStack(alignment: .leading, spacing: 2) {
                Text(turnTitle)
                    .font(.callout.weight(.medium))
                if let detail = turnDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }

        if case .check(let side) = session.match.status, !session.match.status.isGameOver {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(side == .white ? "White is in check" : "Black is in check")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }

        if let countdown = session.opponentGoneClaimWinInSeconds {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                Text("Opponent gone — claim in \(countdown)s")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var moveLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Move")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("#\(session.match.moves.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let last = session.match.moves.last {
                Text(last.uci)
                    .font(.title3.monospaced().weight(.medium))
            }
        }
    }

    @ViewBuilder
    private var gameOverSection: some View {
        if let result = session.result {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: gameOverSymbol(result))
                    Text(gameOverTitle(result))
                        .font(.headline)
                }
                .foregroundStyle(gameOverTint(result))
                Text(gameOverReason(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.isRated, let diff = result.ratingDiff {
                    let sign = diff >= 0 ? "+" : ""
                    Text("Rating: \(sign)\(diff)")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(diff >= 0 ? .green : .red)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if session.result == nil {
                // Game is live → show the action set the server allows
                // right now (abort only before the first move; takeback
                // only when there's at least one move; claim-victory only
                // when the opponent-gone countdown has elapsed).
                HStack(spacing: 8) {
                    Button {
                        Task { await session.offerOrAcceptDraw() }
                    } label: {
                        Label("Draw", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(session.pendingDrawOfferFromUs)

                    Button {
                        Task { await session.offerOrAcceptTakeback() }
                    } label: {
                        Label("Takeback", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(session.match.moves.isEmpty || session.pendingTakebackOfferFromUs)
                }

                if session.canAbort {
                    Button(role: .destructive) {
                        Task { await session.abort() }
                    } label: {
                        Label("Abort game", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button(role: .destructive) {
                        Task { await session.resign() }
                    } label: {
                        Label("Resign", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if session.canClaimVictory {
                    Button {
                        Task { await session.claimVictory() }
                    } label: {
                        Label("Claim victory", systemImage: "trophy.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                // Game over: deep-link to the Lichess analysis board
                // (opens Safari on visionOS as a separate window) and
                // a primary "back to lobby" button that disconnects the
                // session and dismisses the immersive space.
                Button {
                    openURL(session.analysisURL)
                } label: {
                    Label("Analyze on Lichess", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await leaveMatch() }
                } label: {
                    Label("Back to lobby", systemImage: "arrow.left.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // "Move board" is available across both states (live + over).
            // In the over state it doesn't matter much, but it's harmless
            // and keeps the affordance discoverable.
            if let placement {
                Button {
                    placement.reposition()
                } label: {
                    Label("Move board", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            // Pick the immersive backdrop: AR passthrough or one of
            // the bundled virtual environments. Selecting a different
            // env triggers a dismiss + re-open of the immersive since
            // immersionStyle + scene contents need to rebuild. The
            // active Lichess match session is preserved across the
            // re-open via `appModel.pendingReopen` (see ChessSceneView).
            Menu {
                ForEach(SceneEnvironment.allCases) { env in
                    Button {
                        Task { await switchEnvironment(to: env) }
                    } label: {
                        Label(env.displayName, systemImage: env.systemImage)
                        if env == appModel.selectedEnvironment {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(env == appModel.selectedEnvironment)
                }
            } label: {
                Label(
                    appModel.selectedEnvironment.displayName,
                    systemImage: appModel.selectedEnvironment.systemImage
                )
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private func switchEnvironment(to env: SceneEnvironment) async {
        guard env != appModel.selectedEnvironment else { return }
        appModel.selectedEnvironment = env
        appModel.pendingReopen = true
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        default:
            appModel.immersiveSpaceState = .closed
            appModel.pendingReopen = false
        }
    }

    // MARK: - Derived strings / styles

    private var opponentName: String {
        session.opponent.aiLevel.map { "Stockfish-Lichess L\($0)" }
            ?? session.opponent.username
    }

    private var turnTitle: String {
        if session.result != nil { return "Game over" }
        if session.connection != .live { return "Reconnecting…" }
        return session.isHumanTurn ? "Your turn" : "Waiting…"
    }

    private var turnDetail: String? {
        if session.result != nil { return nil }
        let side = session.match.currentPosition.sideToMove
        return side == .white ? "White" : "Black"
    }

    private var highlightWhite: Bool {
        session.result == nil &&
            session.match.currentPosition.sideToMove == .white
    }

    private var highlightBlack: Bool {
        session.result == nil &&
            session.match.currentPosition.sideToMove == .black
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 10, height: 10)
    }

    private var connectionColor: Color {
        switch session.connection {
        case .live: return .green
        case .connecting, .reconnecting: return .yellow
        case .ended: return .secondary
        }
    }

    private var opponentDot: some View {
        Circle()
            .fill(.tint.opacity(0.18))
            .frame(width: 32, height: 32)
            .overlay(
                Text(String(opponentName.prefix(1)).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
            )
    }

    private func sideDot(_ side: Side) -> some View {
        Circle()
            .fill(side == .white ? Color.white : Color.black)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.secondary.opacity(0.6), lineWidth: 0.5))
    }

    private func gameOverSymbol(_ result: LichessMatchSession.Result) -> String {
        switch result.status {
        case .mate, .resign, .timeout, .outoftime: "flag.checkered"
        case .stalemate, .draw: "equal.circle"
        case .aborted: "xmark.circle"
        default: "info.circle"
        }
    }

    private func gameOverTitle(_ result: LichessMatchSession.Result) -> String {
        switch result.status {
        case .mate, .resign, .timeout, .outoftime:
            let userColor: LichessColor = session.humanColor == .white ? .white : .black
            if result.winner == nil { return "Draw" }
            return result.winner == userColor ? "Victory" : "Defeat"
        case .stalemate: return "Stalemate"
        case .draw: return "Draw"
        case .aborted: return "Aborted"
        default: return "Game over"
        }
    }

    private func gameOverReason(_ result: LichessMatchSession.Result) -> String {
        switch result.status {
        case .mate: return "By checkmate."
        case .resign: return "By resignation."
        case .stalemate: return "By stalemate."
        case .draw: return "By agreement or rule."
        case .timeout, .outoftime: return "On time."
        case .aborted: return "Aborted before the first move."
        default: return ""
        }
    }

    private func gameOverTint(_ result: LichessMatchSession.Result) -> Color {
        let userColor: LichessColor = session.humanColor == .white ? .white : .black
        if let winner = result.winner {
            return winner == userColor ? .green : .red
        }
        return .secondary
    }

    private func format(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func leaveMatch() async {
        await session.disconnect()
        appModel.activeSession = nil
        await dismissImmersiveSpace()
    }
}

