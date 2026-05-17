import SwiftUI

/// Navigation payload pushed when the user taps "Review" on a row in
/// the home / game-review list. Carries the game + the requesting
/// username so the detail view can derive sides + opponents.
struct GameReviewRoute: Hashable {
    let game: LichessGame
    let username: String

    static func == (lhs: GameReviewRoute, rhs: GameReviewRoute) -> Bool {
        lhs.game.id == rhs.game.id && lhs.username == rhs.username
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(game.id)
        hasher.combine(username)
    }
}

/// Detail screen for a single Lichess game. Runs the local Stockfish
/// `GameAnalyzer` against every ply, streams the resulting per-move
/// classifications + top-3 candidate lines, and renders them as a
/// scrollable move list with quality glyphs, CP loss, and the engine's
/// suggested alternatives.
///
/// Pushed from `GameRowView`'s Review button via a NavigationLink
/// (`.gameReviewDetail(LichessGame)`).
struct GameReviewDetailView: View {

    let game: LichessGame
    let username: String

    @State private var viewModel: GameReviewDetailViewModel

    init(game: LichessGame, username: String) {
        self.game = game
        self.username = username
        _viewModel = State(initialValue: GameReviewDetailViewModel(game: game))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chess.Space.l) {
                header
                progressBanner
                if !viewModel.moves.isEmpty {
                    summaryRow
                    moveList
                }
                if let error = viewModel.errorMessage {
                    ChessCard(.row) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(Chess.Space.l)
            .frame(maxWidth: 720, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
        .navigationTitle("Review · \(game.opponent(for: username))")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        ChessCard(.hero) {
            HStack(alignment: .top, spacing: Chess.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Chess.Palette.info.opacity(0.18))
                        .frame(width: 46, height: 46)
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Chess.Palette.info)
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: Chess.Space.xxs) {
                    Text("vs \(game.opponent(for: username))")
                        .font(Chess.Typography.sectionTitle())
                    HStack(spacing: Chess.Space.xs) {
                        if let clock = game.clock {
                            ChessChip(clock.displayString, icon: "clock", tint: Chess.Palette.accent)
                        }
                        ChessChip("\(game.moveCount) moves", icon: "square.grid.3x3",
                                  tint: Chess.Palette.highlight)
                    }
                    if let opening = game.opening?.name {
                        Text(opening)
                            .font(Chess.Typography.rowDetail())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Progress banner

    @ViewBuilder
    private var progressBanner: some View {
        if viewModel.isRunning {
            ChessCard(.row) {
                HStack(spacing: Chess.Space.s) {
                    ProgressView()
                        .tint(Chess.Palette.accent)
                    Text("Analysing move \(viewModel.moves.count) / \(viewModel.totalPlies)…")
                        .font(.callout)
                    Spacer()
                    Button("Stop") { viewModel.cancel() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Summary row

    private var summaryRow: some View {
        let result = GameAnalysisResult(moves: viewModel.moves)
        return HStack(spacing: Chess.Space.m) {
            sidePanel(result: result, side: .white, label: "White")
            sidePanel(result: result, side: .black, label: "Black")
        }
    }

    private func sidePanel(
        result: GameAnalysisResult, side: Side, label: String
    ) -> some View {
        let acc = result.accuracy(for: side)
        return ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.xs) {
                HStack {
                    Text(label).font(Chess.Typography.sectionTitle())
                    Spacer()
                    Text(String(format: "%.1f%%", acc))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Chess.Palette.highlight)
                }
                ForEach(qualitiesInDisplayOrder, id: \.self) { q in
                    HStack(spacing: 6) {
                        Text(q.glyph).font(.caption.monospaced())
                            .frame(width: 22)
                            .foregroundStyle(colorFor(q))
                        Text(q.displayName)
                            .font(Chess.Typography.rowDetail())
                        Spacer()
                        Text("\(result.count(q, for: side))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func colorFor(_ q: MoveQuality) -> Color {
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

    private var qualitiesInDisplayOrder: [MoveQuality] {
        [.brilliant, .great, .best, .book, .excellent, .good,
         .inaccuracy, .missedWin, .mistake, .blunder]
    }

    // MARK: - Move list

    private var moveList: some View {
        LazyVStack(spacing: 6) {
            ForEach(viewModel.moves) { m in
                MoveReviewRow(move: m)
            }
        }
    }
}

// MARK: - Move row

private struct MoveReviewRow: View {
    let move: MoveAnalysis

    private var moveNumber: Int { move.id / 2 + 1 }
    private var sideMarker: String { move.id % 2 == 0 ? "." : "..." }

    var body: some View {
        ChessCard(.row) {
            HStack(alignment: .top, spacing: Chess.Space.s) {
                Text("\(moveNumber)\(sideMarker)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Text(move.san)
                    .font(.callout.monospaced())
                    .frame(minWidth: 60, alignment: .leading)

                Text(move.quality.glyph)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(colorFor(move.quality))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: Chess.Space.xxs) {
                    HStack(spacing: 6) {
                        Text(move.quality.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colorFor(move.quality))
                        if move.quality == .book, let name = move.bookOpening {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            if move.winPercentLoss >= 0.5 {
                                Text(String(format: "−%.1f%% win", move.winPercentLoss))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if move.centipawnLoss > 0 {
                                Text("(−\(move.centipawnLoss) cp)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text("eval \(formatScore(move.bestScoreCp))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(move.topLines.prefix(3).enumerated()), id: \.offset) { idx, line in
                        HStack(spacing: 6) {
                            Text("L\(idx + 1)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(line.pv.prefix(8).joined(separator: " "))
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(formatScore(line.scoreCp))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func colorFor(_ q: MoveQuality) -> Color {
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
        let pawns = Double(cp) / 100
        return String(format: "%+.2f", pawns)
    }
}

// MARK: - View model

@Observable
@MainActor
final class GameReviewDetailViewModel {

    let game: LichessGame
    private(set) var moves: [MoveAnalysis] = []
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var totalPlies: Int = 0

    private var task: Task<Void, Never>?
    private var analyzer: GameAnalyzer?

    init(game: LichessGame) {
        self.game = game
        let raw = (game.moves ?? "").split(separator: " ").map(String.init)
        totalPlies = raw.count
    }

    func start() async {
        guard task == nil, !isRunning else { return }
        let uciTokens = (game.moves ?? "").split(separator: " ").map(String.init)
        let parsed = uciTokens.compactMap { Move(uci: $0) }
        guard !parsed.isEmpty else {
            errorMessage = "No moves available for this game."
            return
        }
        isRunning = true
        errorMessage = nil
        moves.removeAll()
        let analyzer = GameAnalyzer(multiPV: 3)
        self.analyzer = analyzer

        task = Task {
            do {
                let stream = await analyzer.analyzeStream(
                    startPosition: .standardStart,
                    moves: parsed,
                    depth: 16
                )
                for try await m in stream {
                    if Task.isCancelled { break }
                    self.moves.append(m)
                }
            } catch is CancellationError {
                // user-initiated cancel; keep partial results
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRunning = false
            await analyzer.shutdown()
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        let analyzer = self.analyzer
        Task { await analyzer?.shutdown() }
        isRunning = false
    }
}
