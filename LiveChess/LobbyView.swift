import SwiftUI

/// Pre-match lobby. Lets the user choose their colour and tune the AI
/// opponent (Stockfish skill 0…20, thinking time 0.5…10 s) before opening
/// the chessboard in the immersive space.
struct LobbyView: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 32) {
            header

            VStack(alignment: .leading, spacing: 24) {
                colorPicker(for: $appModel.matchSettings.humanColor)
                skillSlider(for: $appModel.matchSettings.aiSettings.skillLevel)
                thinkingTimeSlider(for: $appModel.matchSettings.aiSettings.thinkingTime)
            }
            .padding(.horizontal, 8)

            ToggleImmersiveSpaceButton()
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .frame(maxWidth: 540, maxHeight: .infinity, alignment: .top)
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
