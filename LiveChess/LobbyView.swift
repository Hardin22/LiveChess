import SwiftUI

/// Pre-match lobby. Lets the user choose their colour and tune the AI
/// opponent (Stockfish skill 0…20, thinking time 0.5…10 s) before opening
/// the chessboard in the immersive space.
struct LobbyView: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        ScrollView {
            VStack(spacing: 28) {
                header

                lichessCard

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

                ToggleImmersiveSpaceButton()
                    .controlSize(.extraLarge)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 48)
            .frame(maxWidth: 540, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appModel.lichess.bootstrap()
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
