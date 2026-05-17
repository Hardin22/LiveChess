import SwiftUI

/// Pre-match lobby. Lets the user pick a game mode (local Stockfish,
/// online Quick Pair, friend challenge, Lichess Stockfish) and configures
/// it before opening the immersive space.
///
/// Layout philosophy: only one configuration card is visible at a time.
/// A single 4-chip mode picker at the top swaps the card below. The
/// Lichess profile + incoming challenges + active games sit above the
/// picker so they always have visibility regardless of which mode is
/// active.
struct LobbyView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    /// Built lazily after the user signs in to Lichess. Lives across the
    /// lobby's lifetime so the event stream can keep running.
    @State private var lichessLobby: LichessLobbyController?

    /// Whether the piece-customisation sheet is presented. Bound to
    /// the "Pieces" button in the header.
    @State private var showingPieceCustomization: Bool = false

    /// Currently selected mode (drives which configuration card is
    /// visible). Defaults to `.local` so first-time users without a
    /// Lichess account can play immediately. The Main Menu sidebar
    /// can override this via the `initialMode` initializer parameter
    /// so deep-linking to a specific Play sub-item works.
    @State private var selectedMode: GameMode

    /// Designated initializer. The optional `initialMode` overrides the
    /// default landing card — used by the Main Menu sidebar's
    /// Online Game / Local Game / Play with Bot entries.
    init(initialMode: GameMode? = nil) {
        _selectedMode = State(initialValue: initialMode ?? .local)
    }

    /// Selected time control for the online configuration cards.
    @State private var selectedTimeControl: LichessTimeControlSpec =
        .realTime(limitSeconds: 600, incrementSeconds: 0)
    @State private var selectedColor: LichessChallengeColor = .random
    @State private var selectedRated: Bool = false
    @State private var selectedAILevel: Int = 3
    @State private var friendUsername: String = ""

    enum GameMode: String, Hashable, CaseIterable {
        case local, quickPair, friend, lichessBot

        var label: String {
            switch self {
            case .local:       return "Local"
            case .quickPair:   return "Quick Pair"
            case .friend:      return "Friend"
            case .lichessBot:  return "Lichess Bot"
            }
        }

        var icon: String {
            switch self {
            case .local:       return "cpu"
            case .quickPair:   return "person.2.fill"
            case .friend:      return "person.crop.circle.badge.plus"
            case .lichessBot:  return "globe"
            }
        }

        /// True for any mode that requires a Lichess account.
        var requiresSignIn: Bool {
            switch self {
            case .local: return false
            default: return true
            }
        }
    }

    var body: some View {
        @Bindable var appModel = appModel

        // Two-column "settings panel" layout: vertical mode rail on
        // the left (always visible, like Settings.app on visionOS),
        // active mode's configuration card on the right.  Replaces
        // the previous single-column stack that felt like a form
        // page rather than a "let's play now" surface.
        HStack(alignment: .top, spacing: Chess.Space.l) {

            // LEFT — mode rail
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                ChessSectionHeader("Play",
                                   subtitle: "Pick how you want to play.")
                VStack(spacing: Chess.Space.xs) {
                    ForEach(GameMode.allCases, id: \.self) { mode in
                        modeRailRow(mode)
                    }
                }
                Spacer(minLength: 0)
                lichessFooterCard
            }
            .frame(width: 240)

            // RIGHT — header bar + active card
            ScrollView {
                VStack(alignment: .leading, spacing: Chess.Space.m) {
                    slimHeader

                    // Incoming challenges + active games stay above
                    // the config card so "someone's waiting on you"
                    // signals jump out.
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
                    } else {
                        environmentToolbar
                        selectedModeCard
                    }

                    if let error = lichessLobby?.lastError {
                        Label(humanReadable(error),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 620, alignment: .top)
                .padding(.bottom, Chess.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .padding(Chess.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await appModel.lichess.bootstrap()
            ensureLichessLobby()
            // Cheap belt-and-braces refresh while the lobby is visible.
            // Doubles as the auto-open fallback for matches that
            // weren't routed via `gameStart` (event-stream gap, etc.) —
            // see `LichessLobbyController.refreshActiveGames`.
            // 5 s while seeking; 30 s otherwise.
            while !Task.isCancelled {
                let interval: Duration =
                    (lichessLobby?.pendingAction).flatMap {
                        if case .seeking = $0 { return Duration.seconds(5) }
                        return nil
                    } ?? .seconds(30)
                try? await Task.sleep(for: interval)
                await lichessLobby?.refreshActiveGames()
            }
        }
        .onChange(of: appModel.lichess.isSignedIn) { _, _ in
            ensureLichessLobby()
        }
        .onChange(of: appModel.immersiveSpaceState) { _, newState in
            // Once the immersive space is open the lobby's "Found!"
            // indicator has done its job — clear it so the next time
            // the user comes back from the immersive they see the
            // mode picker, not a stale "opening match…" row.
            if newState == .open {
                lichessLobby?.clearPending()
            }
        }
        // (Pieces & Board uses its own WindowGroup now — see
        // LiveChessApp.piecesWindowID. The old .sheet() couldn't be
        // sized wide enough for the side-by-side preview + controls
        // layout on visionOS.)
    }

    // MARK: - Slim header (top bar of the right column)

    /// Brand wordmark on the left, single icon button on the right
    /// for piece customisation. Compact — leaves vertical room for
    /// the actual configuration card to breathe.
    private var slimHeader: some View {
        HStack(spacing: Chess.Space.s) {
            Image(systemName: "crown.fill")
                .foregroundStyle(Chess.Palette.accent)
                .font(.title3)
            Text(Chess.Brand.name)
                .font(.system(size: 26, weight: .semibold, design: .serif))
            Spacer()
            Button {
                openWindow(id: LiveChessApp.piecesWindowID)
            } label: {
                Label("Pieces & board", systemImage: "paintbrush.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Mode rail (left column)

    /// One full-width row per mode in the left rail. The selected
    /// mode gets the accent tint + bolder type; unavailable online
    /// modes (no Lichess auth) are dimmed but still visible so the
    /// user knows what's there.
    @ViewBuilder
    private func modeRailRow(_ mode: GameMode) -> some View {
        let isSelected = mode == selectedMode
        let isAvailable = !mode.requiresSignIn || appModel.lichess.isSignedIn

        Button {
            guard isAvailable else { return }
            selectedMode = mode
            syncDefaultsForMode(mode)
        } label: {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: mode.icon)
                    .foregroundStyle(isSelected
                                     ? .white
                                     : Chess.Palette.accent)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.label)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(modeSubtitle(mode))
                        .font(.caption)
                        .foregroundStyle(isSelected
                                         ? .white.opacity(0.85)
                                         : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Chess.Space.s)
            .padding(.horizontal, Chess.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row,
                                 style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Chess.Palette.accent)
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row,
                                 style: .continuous)
                    .strokeBorder(isSelected
                                  ? Color.clear
                                  : .white.opacity(0.10),
                                  lineWidth: 0.5)
            )
            .opacity(isAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(!isAvailable)
    }

    private func modeSubtitle(_ mode: GameMode) -> String {
        switch mode {
        case .local:      return "On-device · Stockfish"
        case .quickPair:  return "Lichess pool"
        case .friend:     return "Challenge by name"
        case .lichessBot: return "Lichess bots"
        }
    }

    /// Footer-of-the-rail card so the Lichess sign-in / status sits
    /// in the same column as the rest of the rail rather than as a
    /// detached chip at the top of the page.
    @ViewBuilder
    private var lichessFooterCard: some View {
        if !appModel.lichess.isSignedIn {
            ChessCard(.row) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Lichess", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.callout.weight(.medium))
                    Text("Sign in to unlock online modes, ratings, and game review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await appModel.lichess.signIn() }
                    } label: {
                        Text("Sign in")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Environment picker

    /// Single-row picker for the immersive backdrop (AR vs one of the
    /// bundled USDZ environments). Read at the moment the user opens
    /// the immersive space — `ChessSceneView` dispatches on
    /// `appModel.selectedEnvironment` to mount the right scene. Also
    /// drives `immersionStyle` in `LiveChessApp` so virtual envs go
    /// full-immersion and AR stays mixed.
    /// Compact horizontal toolbar that sits directly above the active
    /// config card. Lists every environment as a small chip so the
    /// user can scan options at a glance instead of opening a menu.
    @ViewBuilder
    private var environmentToolbar: some View {
        @Bindable var appModel = appModel
        VStack(alignment: .leading, spacing: 6) {
            Text("Environment")
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Chess.Space.xs) {
                    ForEach(SceneEnvironment.allCases) { env in
                        envChip(env,
                                isSelected: env == appModel.selectedEnvironment) {
                            appModel.selectedEnvironment = env
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func envChip(_ env: SceneEnvironment,
                         isSelected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: env.systemImage)
                Text(env.displayName)
                    .lineLimit(1)
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, Chess.Space.s)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected
                               ? AnyShapeStyle(Chess.Palette.accent)
                               : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                Capsule().strokeBorder(isSelected
                                       ? Color.clear
                                       : .white.opacity(0.12),
                                       lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: - Mode config cards

    @ViewBuilder
    private var selectedModeCard: some View {
        switch selectedMode {
        case .local:       localCard
        case .quickPair:   quickPairCard
        case .friend:      friendChallengeCard
        case .lichessBot:  stockfishCard
        }
    }

    private var localCard: some View {
        @Bindable var appModel = appModel
        return VStack(alignment: .leading, spacing: 18) {
            cardHeader(icon: GameMode.local.icon, title: "Stockfish 17 on this device")
            colorSegment(for: $appModel.matchSettings.humanColor)
            skillSlider(for: $appModel.matchSettings.aiSettings.skillLevel)
            thinkingTimeSlider(for: $appModel.matchSettings.aiSettings.thinkingTime)
            Button {
                Task { await openLocalMatch() }
            } label: {
                Label(
                    appModel.immersiveSpaceState == .open ? "Close board" : "Open board",
                    systemImage: appModel.immersiveSpaceState == .open ? "xmark.circle" : "play.fill"
                )
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(appModel.immersiveSpaceState == .inTransition)
        }
        .padding(Chess.Space.m)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous))
    }

    /// Quick Pair — `/api/board/seek` only allows Rapid+/Correspondence
    /// for OAuth clients (Bullet/Blitz are blocked server-side), so the
    /// preset grid mirrors that constraint.
    @ViewBuilder
    private var quickPairCard: some View {
        configCard(
            icon: GameMode.quickPair.icon,
            title: "Find an opponent in the Lichess pool"
        ) {
            requireSignInOr {
                Toggle("Rated", isOn: $selectedRated)
                timePresets(allowed: .quickPairAllowed)
                Button {
                    guard let lobby = lichessLobby else { return }
                    wireOnGameSessionReadyAndOpenImmersive(lobby)
                    lobby.quickPair(rated: selectedRated, timeControl: selectedTimeControl)
                } label: {
                    Label("Find opponent", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
        }
    }

    /// Friend challenge — `/api/challenge/{username}` accepts every time
    /// control including Bullet / Blitz.
    @ViewBuilder
    private var friendChallengeCard: some View {
        configCard(
            icon: GameMode.friend.icon,
            title: "Challenge a Lichess user by username"
        ) {
            requireSignInOr {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Opponent username")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. magnuscarlsen", text: $friendUsername)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Rated", isOn: $selectedRated)
                timePresets(allowed: .friendAllowed)
                colorChips
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
                    Label(
                        trimmed.isEmpty ? "Challenge" : "Challenge \(trimmed)",
                        systemImage: "paperplane.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(friendUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Lichess Stockfish challenge — always unrated server-side, so no
    /// rated toggle. Levels 1–8.
    @ViewBuilder
    private var stockfishCard: some View {
        configCard(
            icon: GameMode.lichessBot.icon,
            title: "Play Stockfish hosted on Lichess (always casual)"
        ) {
            requireSignInOr {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Level")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(selectedAILevel) / 8")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8),
                        spacing: 6
                    ) {
                        ForEach(1...8, id: \.self) { level in
                            levelChip(level)
                        }
                    }
                }
                timePresets(allowed: .friendAllowed)
                colorChips
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
                    Label("Challenge bot", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
        }
    }

    /// Generic card chrome shared by the 3 online cards. Local has its
    /// own variant because it doesn't need the `requireSignInOr` gate.
    @ViewBuilder
    private func configCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            cardHeader(icon: icon, title: title)
            content()
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cardHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.tint)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// If the user isn't signed in, replaces the card body with a single
    /// sign-in CTA. Otherwise renders `content` as-is.
    @ViewBuilder
    private func requireSignInOr<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        if appModel.lichess.isSignedIn {
            content()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Sign in with Lichess to play online.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await appModel.lichess.signIn() }
                } label: {
                    Label("Sign in with Lichess", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Local game pickers

    private func colorSegment(
        for selection: Binding<MatchSettings.HumanColor>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your color")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                localColorChip(selection, .white, label: "White")
                localColorChip(selection, .black, label: "Black")
                localColorChip(selection, .random, label: "Random")
            }
        }
    }

    @ViewBuilder
    private func localColorChip(
        _ selection: Binding<MatchSettings.HumanColor>,
        _ value: MatchSettings.HumanColor,
        label: String
    ) -> some View {
        let isSelected = selection.wrappedValue == value
        Button {
            selection.wrappedValue = value
        } label: {
            Text(label)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(SelectionButtonStyle(isSelected: isSelected))
        .hoverEffect()
    }

    private func skillSlider(for level: Binding<Int>) -> some View {
        let bounds = Double(AISettings.minSkillLevel)...Double(AISettings.maxSkillLevel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stockfish strength")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(level.wrappedValue) / \(AISettings.maxSkillLevel)")
                    .font(.callout.monospacedDigit())
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
                Text("Beginner").font(.caption2)
                Spacer()
                Text("Maximum").font(.caption2)
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
                Text("Thinking time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.formatSeconds(seconds.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: seconds, in: 0.5...10.0, step: 0.5)
            HStack {
                Text("0.5 s").font(.caption2)
                Spacer()
                Text("10 s").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Online pickers (color, level, time)

    private var colorChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                colorChip(.white, label: "White")
                colorChip(.black, label: "Black")
                colorChip(.random, label: "Random")
            }
        }
    }

    @ViewBuilder
    private func levelChip(_ level: Int) -> some View {
        let isSelected = level == selectedAILevel
        Button {
            selectedAILevel = level
        } label: {
            Text("\(level)")
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(SelectionButtonStyle(isSelected: isSelected))
        .hoverEffect()
    }

    @ViewBuilder
    private func colorChip(_ color: LichessChallengeColor, label: String) -> some View {
        let isSelected = color == selectedColor
        Button {
            selectedColor = color
        } label: {
            Text(label)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(SelectionButtonStyle(isSelected: isSelected))
        .hoverEffect()
    }

    /// Reusable time-control button grid. Filters the master preset
    /// list against the per-mode allowed set.
    @ViewBuilder
    private func timePresets(allowed: TimePresetSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time")
                .font(.caption)
                .foregroundStyle(.secondary)
            let presets = TimePreset.all.filter { allowed.contains($0.speed) }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                spacing: 6
            ) {
                ForEach(presets, id: \.label) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: TimePreset) -> some View {
        let isSelected = preset.spec == selectedTimeControl
        Button {
            selectedTimeControl = preset.spec
        } label: {
            Text(preset.label)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
        }
        .buttonStyle(SelectionButtonStyle(isSelected: isSelected))
        .hoverEffect()
    }

    // MARK: - Pending action / found-match strip

    @ViewBuilder
    private func pendingActionRow(_ action: LichessLobbyController.PendingAction) -> some View {
        HStack(spacing: 12) {
            // Use a checkmark for the matched-state to give a clearer
            // visual signal of "found, opening now" vs the spinner-only
            // "still waiting" states.
            if case .openingMatch = action {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label(for: action))
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            switch action {
            case .seeking:
                Button("Cancel") {
                    lichessLobby?.cancelSeek()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .waitingForOpponent:
                Button("Cancel") {
                    Task { await lichessLobby?.cancelFriendChallenge() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func label(for action: LichessLobbyController.PendingAction) -> String {
        switch action {
        case .creatingAIChallenge(let level):
            return "Creating challenge with Stockfish L\(level)…"
        case .creatingUserChallenge(let username):
            return "Sending challenge to \(username)…"
        case .waitingForOpponent(let id):
            return "Waiting for \(id) to accept…"
        case .seeking(_, let label):
            return "Searching for opponent · \(label)…"
        case .openingMatch(let opponent):
            return "Found \(opponent)! Opening board…"
        }
    }

    // MARK: - Incoming challenges + active games

    @ViewBuilder
    private func incomingChallengesSection(_ lobby: LichessLobbyController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incoming challenges")
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
                        Text(challenge.challenger?.name ?? "Unknown")
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
                    Label("Accept", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive) {
                    Task { await lobby.declineIncoming(challenge.id, reason: nil) }
                } label: {
                    Label("Decline", systemImage: "xmark")
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
                Text("Active games")
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
                    Text("Your turn")
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
            return "Stockfish L\(level)"
        }
        return game.opponent.username
    }

    private func challengeDescription(_ challenge: LichessChallenge) -> String {
        let speedLabel = englishSpeed(challenge.speed)
        let timing = challenge.timeControl.show ?? speedLabel
        let kind = challenge.rated ? "rated" : "casual"
        return "\(speedLabel) · \(timing) · \(kind)"
    }

    private func activeGameSubtitle(_ game: LichessPlayingGame) -> String {
        let speedLabel = englishSpeed(game.speed)
        let kind = game.rated ? "rated" : "casual"
        return "\(speedLabel) · \(kind)"
    }

    private func englishSpeed(_ raw: String) -> String {
        switch raw.lowercased() {
        case "ultrabullet":   return "UltraBullet"
        case "bullet":        return "Bullet"
        case "blitz":         return "Blitz"
        case "rapid":         return "Rapid"
        case "classical":     return "Classical"
        case "correspondence": return "Correspondence"
        default: return raw
        }
    }

    // MARK: - Errors

    private func humanReadable(_ error: LichessError) -> String {
        switch error {
        case .notAuthenticated:  return "Lichess session not authenticated."
        case .tokenExpired:      return "Lichess session expired — sign in again."
        case .scopeInsufficient: return "Insufficient Lichess permissions."
        case .rateLimited:       return "Lichess is rate-limiting — try again in a minute."
        case .clientError(let s, _): return "Lichess error (\(s))."
        case .serverError:       return "Lichess is not responding right now."
        case .decoding:          return "Unrecognized Lichess response."
        case .network:           return "No connection to Lichess."
        case .invalidResponse:   return "Invalid Lichess response."
        }
    }

    // MARK: - Mode default state sync

    /// Sets sensible default time control / colour / level when the user
    /// switches to a different mode chip.
    private func syncDefaultsForMode(_ mode: GameMode) {
        switch mode {
        case .local:
            // Local has its own bindings on AppModel.matchSettings;
            // nothing to sync here.
            break
        case .quickPair:
            selectedTimeControl = .realTime(limitSeconds: 600, incrementSeconds: 0)
            selectedRated = false
        case .friend:
            selectedTimeControl = .realTime(limitSeconds: 300, incrementSeconds: 3)
            selectedRated = false
            selectedColor = .random
        case .lichessBot:
            selectedTimeControl = .realTime(limitSeconds: 600, incrementSeconds: 0)
            selectedColor = .white
            selectedAILevel = 3
        }
    }

    // MARK: - Match opening flows

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

    /// Sets up `lobby.onGameSessionReady` to flip `appModel.activeSession`
    /// and open the immersive space when the game is built.
    ///
    /// Crucial detail for the multi-game lifecycle: if an immersive is
    /// already open from a previous game, we MUST dismiss it before
    /// opening the new one. RealityView's `make` closure runs once and
    /// captures the active session at that time — toggling
    /// `appModel.activeSession` later doesn't trigger a rebuild, so a
    /// new session would render against the previous board state and
    /// be non-interactive (the drag handler still references the dead
    /// session). Dismiss-then-open forces a clean rebuild.
    private func wireOnGameSessionReadyAndOpenImmersive(
        _ lobby: LichessLobbyController
    ) {
        lobby.onGameSessionReady = {
            @MainActor [weak appModel = appModel] matchSession in
            guard let appModel else { return }
            Task { @MainActor in
                if case .online(let old) = appModel.activeSession {
                    await old.disconnect()
                }
                if appModel.immersiveSpaceState == .open {
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                }

                appModel.activeSession = .online(matchSession)
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
        }
    }

    /// Lazily instantiate the Lichess lobby controller once the session
    /// is signed in. Tears it down on sign-out.
    private func ensureLichessLobby() {
        if appModel.lichess.isSignedIn {
            if lichessLobby == nil {
                let lobby = LichessLobbyController(session: appModel.lichess)
                lobby.startEventStreamIfNeeded()
                lobby.onGameFinishReceived = { @MainActor [weak appModel = appModel] info in
                    guard let appModel else { return }
                    guard case .online(let session) = appModel.activeSession else { return }
                    guard session.gameID == info.gameId else { return }
                    session.applyRatingDiff(info.ratingDiff)
                }
                lichessLobby = lobby
                Task { await lobby.refreshActiveGames() }
            }
        } else {
            if let lobby = lichessLobby {
                Task { await lobby.stopEventStream() }
                lichessLobby = nil
            }
        }
    }

    // MARK: - Lichess account card

    @ViewBuilder
    private var lichessCard: some View {
        switch appModel.lichess.status {
        case .unknown:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Checking Lichess session…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

        case .signedOut:
            Button {
                Task { await appModel.lichess.signIn() }
            } label: {
                Label("Sign in with Lichess", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)

        case .signingIn:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Signing in to Lichess…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

        case .signingOut:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Signing out…")
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
                Button("Retry") {
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
            Button("Sign out") {
                Task { await appModel.lichess.signOut() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Number formatting helpers

    private static func duration(_ d: Duration, asSeconds: Void) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func formatSeconds(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s)
    }
}

// MARK: - Time-control presets

private struct TimePreset: Hashable {
    let label: String
    let spec: LichessTimeControlSpec
    let speed: LichessSpeed

    static let all: [TimePreset] = [
        // Bullet
        .init(label: "1+0",   spec: .realTime(limitSeconds: 60, incrementSeconds: 0),   speed: .bullet),
        .init(label: "2+1",   spec: .realTime(limitSeconds: 120, incrementSeconds: 1),  speed: .bullet),
        // Blitz
        .init(label: "3+0",   spec: .realTime(limitSeconds: 180, incrementSeconds: 0),  speed: .blitz),
        .init(label: "3+2",   spec: .realTime(limitSeconds: 180, incrementSeconds: 2),  speed: .blitz),
        .init(label: "5+0",   spec: .realTime(limitSeconds: 300, incrementSeconds: 0),  speed: .blitz),
        .init(label: "5+3",   spec: .realTime(limitSeconds: 300, incrementSeconds: 3),  speed: .blitz),
        // Rapid
        .init(label: "10+0",  spec: .realTime(limitSeconds: 600, incrementSeconds: 0),  speed: .rapid),
        .init(label: "10+5",  spec: .realTime(limitSeconds: 600, incrementSeconds: 5),  speed: .rapid),
        .init(label: "15+10", spec: .realTime(limitSeconds: 900, incrementSeconds: 10), speed: .rapid),
        // Classical
        .init(label: "30+0",  spec: .realTime(limitSeconds: 1800, incrementSeconds: 0),  speed: .classical),
        .init(label: "30+20", spec: .realTime(limitSeconds: 1800, incrementSeconds: 20), speed: .classical),
        // Correspondence
        .init(label: "Daily", spec: .correspondence(daysPerTurn: 3), speed: .correspondence),
    ]
}

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

// MARK: - Selection chip style

/// Toggle-like chip used by the lobby's preset / colour / level / mode
/// selectors. Used in place of `.borderedProminent` vs `.bordered`
/// because the system distinction is too subtle on visionOS for a
/// dense grid where the active option needs to be unmissable.
///
/// Selected: filled accent background + white text + slight scale on
/// press. Unselected: hollow tertiary background + primary text.
private struct SelectionButtonStyle: ButtonStyle {
    enum Shape: Equatable {
        case capsule
        case roundedRect(cornerRadius: CGFloat)
    }

    let isSelected: Bool
    var shape: Shape = .capsule

    func makeBody(configuration: Configuration) -> some View {
        let fill = isSelected
            ? AnyShapeStyle(Chess.Palette.accent)
            : AnyShapeStyle(Color.gray.opacity(0.18))
        let stroke = AnyShapeStyle(Color.secondary.opacity(0.25))
        return configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                switch shape {
                case .capsule:
                    Capsule().fill(fill)
                case .roundedRect(let r):
                    RoundedRectangle(cornerRadius: r, style: .continuous).fill(fill)
                }
            }
            .overlay {
                if !isSelected {
                    switch shape {
                    case .capsule:
                        Capsule().stroke(stroke, lineWidth: 0.5)
                    case .roundedRect(let r):
                        RoundedRectangle(cornerRadius: r, style: .continuous)
                            .stroke(stroke, lineWidth: 0.5)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview(windowStyle: .automatic) {
    LobbyView()
        .environment(AppModel())
}
