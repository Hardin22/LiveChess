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
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var appModel

    @State private var now: Date = .now
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                Text("\(opponentName) offre patta")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Accetta") {
                    Task { await session.offerOrAcceptDraw() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Rifiuta") {
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
                Text("\(opponentName) chiede di annullare")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Accetta") {
                    Task { await session.offerOrAcceptTakeback() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Rifiuta") {
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
        case .notAuthenticated: return "Sessione non autenticata."
        case .tokenExpired: return "Sessione scaduta — torna in lobby per riaccedere."
        case .scopeInsufficient: return "Permessi Lichess insufficienti."
        case .rateLimited: return "Lichess sta limitando — riprova tra un minuto."
        case .clientError: return "Mossa rifiutata da Lichess."
        case .serverError: return "Lichess al momento non risponde."
        case .decoding: return "Risposta non riconosciuta."
        case .network: return "Connessione a Lichess persa."
        case .invalidResponse: return "Risposta Lichess non valida."
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
                Text("Bianco")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(format(milliseconds: session.clock.whiteMillis))
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(highlightWhite ? .primary : .secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Nero")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(format(milliseconds: session.clock.blackMillis))
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(highlightBlack ? .primary : .secondary)
            }
        }
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
                Text(side == .white ? "Bianco è sotto scacco" : "Nero è sotto scacco")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }

        if let countdown = session.opponentGoneClaimWinInSeconds {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                Text("Avversario assente — reclama in \(countdown)s")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var moveLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mossa")
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
                        Label("Patta", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(session.pendingDrawOfferFromUs)

                    Button {
                        Task { await session.offerOrAcceptTakeback() }
                    } label: {
                        Label("Annulla", systemImage: "arrow.uturn.backward")
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
                        Label("Annulla partita", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button(role: .destructive) {
                        Task { await session.resign() }
                    } label: {
                        Label("Abbandona", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if session.canClaimVictory {
                    Button {
                        Task { await session.claimVictory() }
                    } label: {
                        Label("Reclama vittoria", systemImage: "trophy.fill")
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
                    Label("Analizza su Lichess", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await leaveMatch() }
                } label: {
                    Label("Torna alla lobby", systemImage: "arrow.left.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Derived strings / styles

    private var opponentName: String {
        session.opponent.aiLevel.map { "Stockfish-Lichess L\($0)" }
            ?? session.opponent.username
    }

    private var turnTitle: String {
        if session.result != nil { return "Partita conclusa" }
        if session.connection != .live { return "Riconnessione…" }
        return session.isHumanTurn ? "Tocca a te" : "In attesa…"
    }

    private var turnDetail: String? {
        if session.result != nil { return nil }
        let side = session.match.currentPosition.sideToMove
        return side == .white ? "Bianco" : "Nero"
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
            if result.winner == nil { return "Patta" }
            return result.winner == userColor ? "Vittoria" : "Sconfitta"
        case .stalemate: return "Stallo"
        case .draw: return "Patta"
        case .aborted: return "Partita abortita"
        default: return "Partita conclusa"
        }
    }

    private func gameOverReason(_ result: LichessMatchSession.Result) -> String {
        switch result.status {
        case .mate: return "Per scaccomatto."
        case .resign: return "Per abbandono."
        case .stalemate: return "Per stallo."
        case .draw: return "Per accordo o regola."
        case .timeout, .outoftime: return "Per tempo scaduto."
        case .aborted: return "Partita interrotta prima della prima mossa."
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

