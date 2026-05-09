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

    /// Currently selected online mode (which configuration card is
    /// expanded). `nil` = the mode picker is showing the 3 entry-point
    /// buttons.
    @State private var onlineMode: OnlineMode?

    /// Selected time control for the online configuration card. Defaults
    /// to the most popular preset for each mode.
    @State private var selectedTimeControl: LichessTimeControlSpec =
        .realTime(limitSeconds: 600, incrementSeconds: 0)
    @State private var selectedColor: LichessChallengeColor = .random
    @State private var selectedRated: Bool = false
    @State private var selectedAILevel: Int = 3
    @State private var friendUsername: String = ""

    enum OnlineMode: String, Hashable, CaseIterable {
        case quickPair, friend, ai

        var label: String {
            switch self {
            case .quickPair: return "Cerca partita"
            case .friend: return "Sfida amico"
            case .ai: return "Stockfish (Lichess)"
            }
        }

        var icon: String {
            switch self {
            case .quickPair: return "person.2.fill"
            case .friend: return "person.crop.circle.badge.plus"
            case .ai: return "cpu"
            }
        }
    }

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

            // Incoming challenges and active games surface above the mode
            // picker so they're the first thing the user sees on cold
            // start — these are the "someone wants to play with you"
            // signals that should jump out.
            if let lobby = lichessLobby {
                if !lobby.incomingChallenges.isEmpty {
                    incomingChallengesSection(lobby)
                }
                if !lobby.activeGames.isEmpty {
                    activeGamesSection(lobby)
                }
            }

            if let action = lichessLobby?.pendingAction {
                pendingActionRow(action)
            } else if let mode = onlineMode {
                onlineSetupCard(for: mode)
            } else {
                modePicker
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
    private func incomingChallengesSection(_ lobby: LichessLobbyController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sfide ricevute")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(lobby.incomingChallenges, id: \.id) { challenge in
                incomingChallengeRow(challenge, lobby: lobby)
            }
        }
    }

    @ViewBuilder
    private func incomingChallengeRow(
        _ challenge: LichessChallenge,
        lobby: LichessLobbyController
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String((challenge.challenger?.name ?? "?").prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let title = challenge.challenger?.title {
                            Text(title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        Text(challenge.challenger?.name ?? "Sconosciuto")
                            .font(.callout.weight(.medium))
                        if let rating = challenge.challenger?.rating {
                            Text("(\(rating))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(challengeDescription(challenge))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    wireOnGameSessionReadyAndOpenImmersive(lobby)
                    Task { await lobby.acceptIncoming(challenge.id) }
                } label: {
                    Label("Accetta", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(role: .destructive) {
                    Task { await lobby.declineIncoming(challenge.id, reason: nil) }
                } label: {
                    Label("Rifiuta", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func activeGamesSection(_ lobby: LichessLobbyController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Partite in corso")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(lobby.activeGames.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(lobby.activeGames, id: \.gameId) { game in
                activeGameRow(game, lobby: lobby)
            }
        }
    }

    @ViewBuilder
    private func activeGameRow(
        _ game: LichessPlayingGame,
        lobby: LichessLobbyController
    ) -> some View {
        Button {
            wireOnGameSessionReadyAndOpenImmersive(lobby)
            lobby.resumeActiveGame(game)
        } label: {
            HStack(spacing: 10) {
                sideDot(game.color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let title = game.opponent.title {
                            Text(title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        Text(opponentLabel(game))
                            .font(.callout.weight(.medium))
                        if let rating = game.opponent.rating {
                            Text("(\(rating))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(activeGameSubtitle(game))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if game.isMyTurn {
                    Text("Tuo turno")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sideDot(_ color: LichessColor) -> some View {
        Circle()
            .fill(color == .white ? Color.white : Color.black)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.secondary.opacity(0.6), lineWidth: 0.5))
    }

    private func opponentLabel(_ game: LichessPlayingGame) -> String {
        if let level = game.opponent.aiLevel {
            return "Stockfish-Lichess L\(level)"
        }
        return game.opponent.username
    }

    private func challengeDescription(_ challenge: LichessChallenge) -> String {
        let speedLabel: String = {
            switch challenge.speed.lowercased() {
            case "ultrabullet": return "UltraBullet"
            case "bullet": return "Bullet"
            case "blitz": return "Blitz"
            case "rapid": return "Rapid"
            case "classical": return "Classical"
            case "correspondence": return "Corrispondenza"
            default: return challenge.speed
            }
        }()
        let timing = challenge.timeControl.show ?? speedLabel
        let kind = challenge.rated ? "rated" : "casual"
        return "\(speedLabel) · \(timing) · \(kind)"
    }

    private func activeGameSubtitle(_ game: LichessPlayingGame) -> String {
        let speedLabel: String = {
            switch game.speed.lowercased() {
            case "ultrabullet": return "UltraBullet"
            case "bullet": return "Bullet"
            case "blitz": return "Blitz"
            case "rapid": return "Rapid"
            case "classical": return "Classical"
            case "correspondence": return "Corrispondenza"
            default: return game.speed
            }
        }()
        let kind = game.rated ? "rated" : "casual"
        return "\(speedLabel) · \(kind)"
    }

    /// Three side-by-side entry buttons that swap to the corresponding
    /// configuration card on tap.
    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(OnlineMode.allCases, id: \.self) { mode in
                Button {
                    onlineMode = mode
                    syncDefaultsForMode(mode)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.title2)
                        Text(mode.label)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func onlineSetupCard(for mode: OnlineMode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    onlineMode = nil
                } label: {
                    Image(systemName: "chevron.left")
                    Text("Indietro")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Label(mode.label, systemImage: mode.icon)
                    .font(.headline)
            }

            switch mode {
            case .quickPair: quickPairCard
            case .friend: friendChallengeCard
            case .ai: stockfishCard
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Quick Pair — `/api/board/seek` only allows Rapid+/Correspondence
    /// for OAuth clients (Bullet/Blitz are blocked server-side), so the
    /// preset grid mirrors that constraint.
    @ViewBuilder
    private var quickPairCard: some View {
        Toggle("Rated", isOn: $selectedRated)
        timePresets(allowed: .quickPairAllowed)
        Button {
            guard let lobby = lichessLobby else { return }
            wireOnGameSessionReadyAndOpenImmersive(lobby)
            lobby.quickPair(rated: selectedRated, timeControl: selectedTimeControl)
        } label: {
            Label("Cerca avversario", systemImage: "person.2.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    /// Friend challenge — `/api/challenge/{username}` accepts every time
    /// control including Bullet / Blitz.
    @ViewBuilder
    private var friendChallengeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Username avversario")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("es. magnuscarlsen", text: $friendUsername)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Toggle("Rated", isOn: $selectedRated)
        timePresets(allowed: .friendAllowed)
        colorPicker
        Button {
            guard let lobby = lichessLobby else { return }
            wireOnGameSessionReadyAndOpenImmersive(lobby)
            Task {
                await lobby.challengeFriend(
                    username: friendUsername,
                    rated: selectedRated,
                    timeControl: selectedTimeControl,
                    color: selectedColor
                )
            }
        } label: {
            let trimmed = friendUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            Label(trimmed.isEmpty ? "Sfida" : "Sfida \(trimmed)", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(friendUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Lichess Stockfish challenge — always unrated server-side, so no
    /// rated toggle. Levels 1–8.
    @ViewBuilder
    private var stockfishCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Livello")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedAILevel) / 8")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Picker("Livello", selection: $selectedAILevel) {
                ForEach(1...8, id: \.self) { level in
                    Text("\(level)").tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        timePresets(allowed: .friendAllowed)
        colorPicker
        Button {
            guard let lobby = lichessLobby else { return }
            wireOnGameSessionReadyAndOpenImmersive(lobby)
            Task {
                await lobby.challengeAI(
                    level: selectedAILevel,
                    timeControl: selectedTimeControl,
                    color: selectedColor
                )
            }
        } label: {
            Label("Sfida Stockfish (Lichess)", systemImage: "cpu")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colore")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Colore", selection: $selectedColor) {
                Text("Bianco").tag(LichessChallengeColor.white)
                Text("Nero").tag(LichessChallengeColor.black)
                Text("Random").tag(LichessChallengeColor.random)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Reusable time-control button grid. Filters the master preset
    /// list against the per-mode allowed set.
    @ViewBuilder
    private func timePresets(allowed: TimePresetSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tempo")
                .font(.caption)
                .foregroundStyle(.secondary)
            let presets = TimePreset.all.filter { allowed.contains($0.speed) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets, id: \.label) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    /// Single preset cell. Splits into two branches because Swift can't
    /// unify `BorderedProminentButtonStyle` and `BorderedButtonStyle`
    /// in a ternary on `.buttonStyle(...)`.
    @ViewBuilder
    private func presetButton(_ preset: TimePreset) -> some View {
        if preset.spec == selectedTimeControl {
            Button {
                selectedTimeControl = preset.spec
            } label: {
                Text(preset.label)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            Button {
                selectedTimeControl = preset.spec
            } label: {
                Text(preset.label)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func pendingActionRow(_ action: LichessLobbyController.PendingAction) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(label(for: action))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            switch action {
            case .seeking:
                Button("Annulla") {
                    lichessLobby?.cancelSeek()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .waitingForOpponent:
                Button("Annulla") {
                    Task { await lichessLobby?.cancelFriendChallenge() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    /// Make sure the picker defaults match a sensible preset for the
    /// chosen mode (Quick Pair limits us to Rapid+; AI allows fastest).
    private func syncDefaultsForMode(_ mode: OnlineMode) {
        switch mode {
        case .quickPair:
            // 10+0 is the most popular Rapid pool.
            selectedTimeControl = .realTime(limitSeconds: 600, incrementSeconds: 0)
            selectedRated = false
        case .friend:
            // 5+3 Blitz is a nice friendly default.
            selectedTimeControl = .realTime(limitSeconds: 300, incrementSeconds: 3)
            selectedRated = false
            selectedColor = .random
        case .ai:
            // 10+0 vs Stockfish — gives both engines a chance to think.
            selectedTimeControl = .realTime(limitSeconds: 600, incrementSeconds: 0)
            selectedColor = .white
            selectedAILevel = 3
        }
    }

    /// Sets up `lobby.onGameSessionReady` to flip `appModel.activeSession`
    /// and open the immersive space when the game is built. Used by all
    /// three online flows.
    private func wireOnGameSessionReadyAndOpenImmersive(
        _ lobby: LichessLobbyController
    ) {
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

    /// Lazily instantiate the Lichess lobby controller once the session
    /// is signed in. Tears it down on sign-out.
    private func ensureLichessLobby() {
        if appModel.lichess.isSignedIn {
            if lichessLobby == nil {
                let lobby = LichessLobbyController(session: appModel.lichess)
                lobby.startEventStreamIfNeeded()
                lichessLobby = lobby
                // Pull current active games so they appear immediately
                // on cold start. The event stream will keep them in
                // sync from here on.
                Task { await lobby.refreshActiveGames() }
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

// MARK: - Time-control presets

/// One row of the lobby's time-control button grid. The list mirrors
/// what the lichess.org "Quick Pair" picker offers.
private struct TimePreset: Hashable {
    let label: String
    let spec: LichessTimeControlSpec
    let speed: LichessSpeed

    static let all: [TimePreset] = [
        // Bullet
        .init(label: "1+0",  spec: .realTime(limitSeconds: 60, incrementSeconds: 0),  speed: .bullet),
        .init(label: "2+1",  spec: .realTime(limitSeconds: 120, incrementSeconds: 1), speed: .bullet),
        // Blitz
        .init(label: "3+0",  spec: .realTime(limitSeconds: 180, incrementSeconds: 0), speed: .blitz),
        .init(label: "3+2",  spec: .realTime(limitSeconds: 180, incrementSeconds: 2), speed: .blitz),
        .init(label: "5+0",  spec: .realTime(limitSeconds: 300, incrementSeconds: 0), speed: .blitz),
        .init(label: "5+3",  spec: .realTime(limitSeconds: 300, incrementSeconds: 3), speed: .blitz),
        // Rapid
        .init(label: "10+0", spec: .realTime(limitSeconds: 600, incrementSeconds: 0), speed: .rapid),
        .init(label: "10+5", spec: .realTime(limitSeconds: 600, incrementSeconds: 5), speed: .rapid),
        .init(label: "15+10", spec: .realTime(limitSeconds: 900, incrementSeconds: 10), speed: .rapid),
        // Classical
        .init(label: "30+0", spec: .realTime(limitSeconds: 1800, incrementSeconds: 0), speed: .classical),
        .init(label: "30+20", spec: .realTime(limitSeconds: 1800, incrementSeconds: 20), speed: .classical),
        // Correspondence
        .init(label: "Corrisp.", spec: .correspondence(daysPerTurn: 3), speed: .correspondence),
    ]
}

/// Which speeds are allowed for a given lobby flow. Quick Pair is
/// constrained server-side to Rapid+; friend challenges + AI accept
/// everything (correspondence included via the Corrisp. preset).
private struct TimePresetSet {
    let speeds: Set<LichessSpeed>

    func contains(_ speed: LichessSpeed) -> Bool {
        speeds.contains(speed)
    }

    /// Quick Pair pool — Bullet/Blitz blocked server-side for OAuth
    /// Board API consumers (`SetupForm.scala:isBoardCompatible`).
    static let quickPairAllowed = TimePresetSet(speeds: [.rapid, .classical, .correspondence])

    /// Friend challenges + AI challenges — full set.
    static let friendAllowed = TimePresetSet(speeds: [.bullet, .blitz, .rapid, .classical, .correspondence])
}

#Preview(windowStyle: .automatic) {
    LobbyView()
        .environment(AppModel())
}
