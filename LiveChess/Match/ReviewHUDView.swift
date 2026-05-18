import SwiftUI

/// Floating HUD shown next to the immersive 3-D board while reviewing
/// a finished game. Drives `ReviewSession`'s navigation, surfaces the
/// engine's per-move classification, and lets the user exit back to
/// the main menu.
@MainActor
struct ReviewHUDView: View {

    @Bindable var session: ReviewSession
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            header
            Divider()
            classificationCard
            engineLineCard
            Divider()
            navigationBar
            if session.isInVariation { variationFooter }
            exitButton
        }
        .padding(Chess.Space.m)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in:
                        RoundedRectangle(cornerRadius: Chess.Radius.card,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear { session.startAnalysisIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Chess.Space.xs) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(Chess.Palette.info)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.titleLine)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(session.subtitleLine) · \(session.resultLine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Classification badge for current ply

    @ViewBuilder
    private var classificationCard: some View {
        if let c = session.currentClassification {
            HStack(spacing: 8) {
                Text(c.quality.glyph)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(qualityColor(c.quality))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.quality.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(qualityColor(c.quality))
                    if c.quality == .book, let opening = c.bookOpening {
                        Text(opening)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if c.winPercentLoss >= 0.5 {
                        Text(String(format: "−%.1f%% win  (−%d cp)",
                                    c.winPercentLoss, c.centipawnLoss))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Chess.Space.s)
            .background(.thinMaterial, in:
                            RoundedRectangle(cornerRadius: Chess.Radius.row))
        } else if session.isAnalyzing {
            HStack(spacing: 6) {
                ProgressView().tint(Chess.Palette.accent)
                Text("Analysing \(session.analysisResults.count) / \(session.plyMoves.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if session.currentPly < 0 {
            Text("Starting position")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var engineLineCard: some View {
        if let c = session.currentClassification, !c.topLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(c.topLines.prefix(3).enumerated()),
                        id: \.offset) { idx, line in
                    HStack(spacing: 8) {
                        Text(formatScore(line.scoreCp))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(line.scoreCp >= 0
                                             ? Chess.Palette.accent : .red)
                            .frame(width: 50, alignment: .leading)
                        Text(line.pv.prefix(6).joined(separator: " "))
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        VStack(spacing: Chess.Space.xs) {
            Text(session.plyLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: Chess.Space.xs) {
                navButton("backward.end.fill") { session.goToStart() }
                navButton("chevron.backward",
                          disabled: !session.canStepBack) { session.stepBack() }
                navButton(session.isAutoPlaying ? "pause.fill" : "play.fill",
                          highlighted: true) { session.toggleAutoPlay() }
                navButton("chevron.forward",
                          disabled: !session.canStepForward) { session.stepForward() }
                navButton("forward.end.fill") { session.goToEnd() }
            }
        }
    }

    @ViewBuilder
    private func navButton(_ symbol: String,
                           disabled: Bool = false,
                           highlighted: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(highlighted ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    highlighted ? AnyShapeStyle(Chess.Palette.accent)
                                : AnyShapeStyle(.thinMaterial),
                    in: RoundedRectangle(cornerRadius: Chess.Radius.chip)
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    /// Surfaced only when the user has branched off the main game line
    /// via a piece drag. Shows the variation length + a button to
    /// snap the board back to the main-line position at `currentPly`.
    private var variationFooter: some View {
        HStack(spacing: Chess.Space.s) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Chess.Palette.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("Side line · \(session.variation.count) \(session.variation.count == 1 ? "move" : "moves")")
                    .font(.callout.weight(.semibold))
                Text("Drag pieces to keep exploring")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                session.clearVariation()
            } label: {
                Label("Back", systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Chess.Space.s)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: Chess.Radius.row))
    }

    private var exitButton: some View {
        Button(role: .destructive) {
            Task {
                session.tearDown()
                appModel.activeSession = nil
                await dismissImmersiveSpace()
            }
        } label: {
            Label("Exit review", systemImage: "house.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: - Helpers

    private func qualityColor(_ q: MoveQuality) -> Color {
        switch q {
        case .brilliant:         return .cyan
        case .best, .great:      return Chess.Palette.accent
        case .book:              return Chess.Palette.info
        case .excellent, .good:  return .mint
        case .inaccuracy:        return Chess.Palette.highlight
        case .missedWin:         return .purple
        case .mistake:           return .orange
        case .blunder:           return .red
        }
    }

    private func formatScore(_ cp: Int) -> String {
        if cp >= 9000 { return "M\(10_000 - cp)" }
        if cp <= -9000 { return "-M\(10_000 + cp)" }
        return String(format: "%+.2f", Double(cp) / 100)
    }
}
