import SwiftUI

/// Pre-match lobby. Lets the user pick their flavour of game (local AI,
/// online Lichess Stockfish — and in later phases, Quick Pair + friend
/// challenge) and configures it before opening the immersive space.
struct LobbyView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Built lazily after the user signs in to Lichess. Lives across the
    /// lobby's lifetime so the event stream can keep running.
    @State private var lichessLobby: LichessLobbyController?

    var body: some View {
        @Bindable var appModel = appModel

        ScrollView {
            VStack(spacing: 28) {
                header

                lichessCard

                if appModel.lichess.isSignedIn {
                    Divider()
                    onlineSection
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Partita locale")
                        .font(.headline)
                    Text("Stockfish 17 sul tuo Apple Vision Pro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 24) {
                    colorPicker(for: $appModel.matchSettings.humanColor)
                    skillSlider(for: $appModel.matchSettings.aiSettings.skillLevel)
                    thinkingTimeSlider(for: $appModel.matchSettings.aiSettings.thinkingTime)
                }
                .padding(.horizontal, 8)

                Button {
                    Task { await openLocalMatch() }
                } label: {
                    Text(appModel.immersiveSpaceState == .open ? "Chiudi scacchiera" : "Apri scacchiera")
                        .fontWeight(.semibold)
                }
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .disabled(appModel.immersiveSpaceState == .inTransition)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 48)
            .frame(maxWidth: 540, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appModel.lichess.bootstrap()
            ensureLichessLobby()
        }
        .onChange(of: appModel.lichess.isSignedIn) { _, _ in
            ensureLichessLobby()
        }
    }

    // MARK: - Online section

    @ViewBuilder
    private var onlineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Online — Lichess")
                .font(.headline)
            Text("Sfida lo Stockfish ospitato da Lichess (le partite sono sempre casual).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let action = lichessLobby?.pendingAction {
                pendingActionRow(action)
            } else {
                Button {
                    Task { await openOnlineAIMatch() }
                } label: {
                    Label("Sfida Stockfish (Lichess)", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }

            if let error = lichessLobby?.lastError {
                Label(humanReadable(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func pendingActionRow(_ action: LichessLobbyController.PendingAction) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(label(for: action))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func label(for action: LichessLobbyController.PendingAction) -> String {
        switch action {
        case .creatingAIChallenge(let level):
            return "Creazione sfida con Stockfish L\(level)…"
        case .creatingUserChallenge(let username):
            return "Sfida \(username) in invio…"
        case .waitingForOpponent(let id):
            return "In attesa che \(id) accetti…"
        case .seeking(_, let label):
            return "Cerco avversario \(label)…"
        }
    }

    private func humanReadable(_ error: LichessError) -> String {
        switch error {
        case .notAuthenticated: return "Sessione Lichess non autenticata."
        case .tokenExpired: return "Sessione Lichess scaduta — riaccedi."
        case .scopeInsufficient: return "Permessi Lichess insufficienti."
        case .rateLimited: return "Lichess sta limitando le richieste — riprova tra un minuto."
        case .clientError(let s, _): return "Errore Lichess (\(s))."
        case .serverError: return "Lichess al momento non risponde."
        case .decoding: return "Risposta Lichess non riconosciuta."
        case .network: return "Nessuna connessione a Lichess."
        case .invalidResponse: return "Risposta Lichess non valida."
        }
    }

    // MARK: - Match opening flows

    /// Builds a local `MatchCoordinator` from the current `MatchSettings`
    /// and opens the immersive space. Replaces the old
    /// `ToggleImmersiveSpaceButton` flow so the scene host doesn't have
    /// to construct the coordinator inline.
    private func openLocalMatch() async {
        if appModel.immersiveSpaceState == .open {
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            return
        }
        let rules = ChessKitRulesEngine()
        let humanSide = appModel.matchSettings.resolvedHumanSide()
        let whiteController: MatchCoordinator.SideController =
            humanSide == .white ? .human : .ai(appModel.matchSettings.aiSettings)
        let blackController: MatchCoordinator.SideController =
            humanSide == .black ? .human : .ai(appModel.matchSettings.aiSettings)
        let coordinator = MatchCoordinator(
            match: Match(),
            rules: rules,
            ai: StockfishEngine(),
            white: whiteController,
            black: blackController
        )
        appModel.activeSession = .local(coordinator)
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        case .userCancelled, .error:
            appModel.immersiveSpaceState = .closed
            appModel.activeSession = nil
        @unknown default:
            appModel.immersiveSpaceState = .closed
            appModel.activeSession = nil
        }
    }

    /// Issues an AI challenge against Lichess' hosted Stockfish at the
    /// chosen level + time, builds a `LichessMatchSession` from the
    /// response and opens the immersive space wired to it. Phase-7
    /// defaults: level 3, 10+0 Rapid, white. The configurable picker
    /// lands in phase 9.
    private func openOnlineAIMatch() async {
        guard let lobby = lichessLobby else { return }
        lobby.onGameSessionReady = { @MainActor [weak appModel = appModel] matchSession in
            guard let appModel else { return }
            appModel.activeSession = .online(matchSession)
            appModel.immersiveSpaceState = .inTransition
            Task { @MainActor in
                switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                case .opened:
                    break
                case .userCancelled, .error:
                    appModel.immersiveSpaceState = .closed
                    appModel.activeSession = nil
                @unknown default:
                    appModel.immersiveSpaceState = .closed
                    appModel.activeSession = nil
                }
            }
        }
        await lobby.challengeAI(
            level: 3,
            timeControl: .realTime(limitSeconds: 600, incrementSeconds: 0),
            color: .white
        )
    }

    /// Lazily instantiate the Lichess lobby controller once the session
    /// is signed in. Tears it down on sign-out.
    private func ensureLichessLobby() {
        if appModel.lichess.isSignedIn {
            if lichessLobby == nil {
                let lobby = LichessLobbyController(session: appModel.lichess)
                lobby.startEventStreamIfNeeded()
                lichessLobby = lobby
            }
        } else {
            if let lobby = lichessLobby {
                Task { await lobby.stopEventStream() }
                lichessLobby = nil
            }
        }
    }

    // MARK: - Lichess card

    @ViewBuilder
    private var lichessCard: some View {
        switch appModel.lichess.status {
        case .unknown:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Verifica sessione Lichess…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

        case .signedOut:
            Button {
                Task { await appModel.lichess.signIn() }
            } label: {
                Label("Accedi con Lichess", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)

        case .signingIn:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Accesso a Lichess in corso…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

        case .signingOut:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Logout in corso…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

        case .signedIn(let account):
            profileCard(account: account)

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Riprova") {
                    Task { await appModel.lichess.bootstrap() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
        }
    }

    private func profileCard(account: LichessAccount) -> some View {
        let initials = String(account.username.prefix(2)).uppercased()
        let rapid = account.rating(forPerfKey: "rapid")
        let blitz = account.rating(forPerfKey: "blitz")
        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let title = account.title {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    Text(account.username)
                        .font(.headline)
                }
                HStack(spacing: 12) {
                    if let rapid {
                        Text("Rapid \(rapid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let blitz {
                        Text("Blitz \(blitz)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            Button("Logout") {
                Task { await appModel.lichess.signOut() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Text("LiveChess")
                .font(.system(size: 44, weight: .semibold, design: .serif))
            Text("Una partita contro Stockfish, in mixed reality.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func colorPicker(for selection: Binding<MatchSettings.HumanColor>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Il tuo colore")
                .font(.headline)
            Picker("", selection: selection) {
                Text("Bianco").tag(MatchSettings.HumanColor.white)
                Text("Nero").tag(MatchSettings.HumanColor.black)
                Text("Random").tag(MatchSettings.HumanColor.random)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func skillSlider(for level: Binding<Int>) -> some View {
        let bounds = Double(AISettings.minSkillLevel)...Double(AISettings.maxSkillLevel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Forza Stockfish")
                    .font(.headline)
                Spacer()
                Text("\(level.wrappedValue)")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(level.wrappedValue) },
                    set: { level.wrappedValue = Int($0.rounded()) }
                ),
                in: bounds,
                step: 1
            )
            HStack {
                Text("0 (principiante)").font(.caption2)
                Spacer()
                Text("20 (massimo)").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func thinkingTimeSlider(for time: Binding<Duration>) -> some View {
        let seconds = Binding(
            get: { Self.duration(time.wrappedValue, asSeconds: ()) },
            set: { time.wrappedValue = .milliseconds(Int($0 * 1000)) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tempo di riflessione")
                    .font(.headline)
                Spacer()
                Text(Self.formatSeconds(seconds.wrappedValue))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: seconds, in: 0.5...10.0, step: 0.5)
            HStack {
                Text("0,5 s").font(.caption2)
                Spacer()
                Text("10 s").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private static func duration(_ d: Duration, asSeconds: Void) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func formatSeconds(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",")
    }
}

#Preview(windowStyle: .automatic) {
    LobbyView()
        .environment(AppModel())
}
