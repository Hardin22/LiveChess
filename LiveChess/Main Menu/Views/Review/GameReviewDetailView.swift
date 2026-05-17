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

/// chess.com-style game review screen for Chess+ on visionOS.
///
/// Layout (left → right):
///   1. **Eval bar** — vertical bar visualising the engine eval at the
///      currently selected ply (top = winning for Black, bottom = White).
///   2. **Board** — 2-D `ReviewBoardView` with arrows for the played
///      move (yellow) and the engine's preferred move (accent green).
///   3. **Analysis panel** — player matchup header, top engine PV
///      lines for the current position, move list with classification
///      glyphs, and First / Prev / Next / Last navigation arrows.
///
/// Background:
///   * Engine work is owned by `GameAnalyzer` (Stockfish 17, MultiPV 3,
///     depth 16, win% + brilliant + book classification).
///   * Moves stream in ply by ply via `AsyncThrowingStream`, so the
///     move list fills progressively while the user is already
///     scrubbing through what's loaded.
///   * Stops cleanly on `onDisappear` (engine `stop` + task cancel).
struct GameReviewDetailView: View {

    let game: LichessGame
    let username: String

    @State private var viewModel: GameReviewDetailViewModel

    init(game: LichessGame, username: String) {
        self.game = game
        self.username = username
        _viewModel = State(initialValue: GameReviewDetailViewModel(
            game: game, username: username))
    }

    var body: some View {
        HStack(alignment: .top, spacing: Chess.Space.m) {
            // LEFT: Eval bar + board column
            VStack(spacing: Chess.Space.s) {
                playersBar
                HStack(alignment: .top, spacing: Chess.Space.s) {
                    EvalBar(winPercent: viewModel.currentWinPercent)
                        .frame(width: 22, height: 460)
                    boardSurface
                }
                navigationBar
            }
            .frame(width: 540)

            // RIGHT: Analysis panel
            analysisColumn
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(Chess.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassBackgroundEffect()
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Top players bar

    private var playersBar: some View {
        ChessCard(.row) {
            HStack(spacing: Chess.Space.s) {
                playerChip(
                    name: game.players.white.user?.name ?? "White",
                    rating: game.players.white.rating,
                    isWinner: game.winner == "white"
                )
                Spacer()
                Text(resultString)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Chess.Palette.highlight)
                Spacer()
                playerChip(
                    name: game.players.black.user?.name ?? "Black",
                    rating: game.players.black.rating,
                    isWinner: game.winner == "black"
                )
            }
        }
    }

    private func playerChip(name: String, rating: Int?, isWinner: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isWinner
                          ? Chess.Palette.accent
                          : Color.gray.opacity(0.5))
                    .frame(width: 22, height: 22)
                Text(String(name.prefix(1)).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let r = rating {
                    Text("\(r)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resultString: String {
        if game.winner == "white" { return "1 – 0" }
        if game.winner == "black" { return "0 – 1" }
        return "½ – ½"
    }

    // MARK: - Board surface

    @ViewBuilder
    private var boardSurface: some View {
        ChessCard(.standard) {
            VStack(spacing: Chess.Space.xs) {
                ReviewBoardView(
                    position: viewModel.currentPosition,
                    playedMove: viewModel.playedMoveAtCurrent,
                    bestMove: viewModel.bestMoveAtCurrent,
                    flipped: humanIsBlack
                )
                .frame(height: 460)

                if let badge = viewModel.currentClassificationBadge {
                    HStack(spacing: 6) {
                        Text(badge.quality.glyph)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(badge.color)
                        Text(badge.quality.displayName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(badge.color)
                        if let line = badge.detail {
                            Text(line)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var humanIsBlack: Bool {
        game.players.black.user?.name.lowercased() == username.lowercased()
    }

    // MARK: - Navigation bar (|< < play > >|)

    private var navigationBar: some View {
        ChessCard(.row) {
            HStack(spacing: Chess.Space.s) {
                navButton("backward.end.fill") { viewModel.goToStart() }
                navButton("chevron.backward") { viewModel.stepBack() }
                Spacer()
                Text(viewModel.plyLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                navButton(viewModel.isAutoPlaying
                          ? "pause.fill" : "play.fill") {
                    viewModel.toggleAutoPlay()
                }
                navButton("chevron.forward") { viewModel.stepForward() }
                navButton("forward.end.fill") { viewModel.goToEnd() }
            }
        }
    }

    @ViewBuilder
    private func navButton(_ symbol: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 38, height: 32)
                .background(.thinMaterial, in:
                                RoundedRectangle(cornerRadius: Chess.Radius.chip))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: - Right column: analysis

    @ViewBuilder
    private var analysisColumn: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            // Engine lines for the position BEFORE the current move
            engineLinesCard
            // Move list with classification glyphs
            moveListCard
        }
    }

    @ViewBuilder
    private var engineLinesCard: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                HStack(spacing: Chess.Space.xs) {
                    Image(systemName: "cpu")
                        .foregroundStyle(Chess.Palette.info)
                    Text("Engine analysis")
                        .font(Chess.Typography.sectionTitle())
                    Spacer()
                    if let depth = viewModel.currentDepth {
                        ChessChip("depth \(depth)", tint: Chess.Palette.info)
                    }
                }
                if let opening = viewModel.openingForCurrentPly {
                    HStack(spacing: 6) {
                        Image(systemName: "book.closed")
                            .foregroundStyle(Chess.Palette.info)
                        Text(opening)
                            .font(Chess.Typography.rowDetail())
                            .foregroundStyle(.secondary)
                    }
                }
                if viewModel.currentLines.isEmpty {
                    if viewModel.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().tint(Chess.Palette.accent)
                            Text(viewModel.progressLabel)
                                .font(Chess.Typography.rowDetail())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No engine analysis for this ply.")
                            .font(Chess.Typography.rowDetail())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(viewModel.currentLines.enumerated()),
                            id: \.offset) { idx, line in
                        engineLineRow(index: idx, line: line)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func engineLineRow(index: Int, line: AnalysisLine) -> some View {
        HStack(spacing: 8) {
            Text(formatScore(line.scoreCp))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(line.scoreCp >= 0
                                 ? Chess.Palette.accent
                                 : Color.red)
                .frame(width: 56, alignment: .leading)
            Text(line.pv.prefix(10).joined(separator: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var moveListCard: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                HStack {
                    Image(systemName: "list.number")
                        .foregroundStyle(Chess.Palette.info)
                    Text("Moves")
                        .font(Chess.Typography.sectionTitle())
                    Spacer()
                    if !viewModel.moves.isEmpty {
                        let result = GameAnalysisResult(moves: viewModel.moves)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(String(format: "%.1f%%",
                                        result.accuracy(for: .white)))
                            + Text(" · ")
                                .foregroundStyle(.secondary)
                            + Text(String(format: "%.1f%%",
                                          result.accuracy(for: .black)))
                        }
                        .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                if viewModel.moves.isEmpty {
                    if let err = viewModel.errorMessage {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    moveGrid
                }
            }
        }
    }

    /// Two-column move grid (1. e4 | e5  • 2. Nf3 | Nc6 …) with the
    /// classification glyph rendered inline after the move text and
    /// the currently-selected ply highlighted in accent green.
    private var moveGrid: some View {
        let pairs = viewModel.movePairs
        return LazyVGrid(
            columns: [
                GridItem(.fixed(28), alignment: .trailing),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ],
            spacing: 4
        ) {
            ForEach(pairs.indices, id: \.self) { idx in
                let pair = pairs[idx]
                Text("\(pair.number).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                moveCell(pair.white, plyIndex: idx * 2)
                moveCell(pair.black, plyIndex: idx * 2 + 1)
            }
        }
    }

    @ViewBuilder
    private func moveCell(_ entry: GameReviewDetailViewModel.MoveEntry?,
                          plyIndex: Int) -> some View {
        if let entry {
            Button {
                viewModel.goTo(ply: plyIndex)
            } label: {
                HStack(spacing: 4) {
                    Text(entry.san)
                        .font(.callout.monospaced())
                    if let q = entry.quality, q != .best {
                        Text(q.glyph)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(qualityColor(q))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    viewModel.currentPly == plyIndex
                        ? Chess.Palette.accent.opacity(0.30)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: Chess.Radius.chip)
                )
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        } else {
            Color.clear.frame(height: 1)
        }
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
        let pawns = Double(cp) / 100
        return String(format: "%+.2f", pawns)
    }
}

// MARK: - Eval bar

/// Vertical evaluation bar. `winPercent` is white's expected score
/// (0…100). Larger = more white area at the bottom (white POV).
struct EvalBar: View {
    let winPercent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                Rectangle()
                    .fill(Color.white)
                    .frame(height: geo.size.height * CGFloat(winPercent / 100))
                    .animation(.spring(response: 0.3, dampingFraction: 0.85),
                               value: winPercent)
            }
            .clipShape(RoundedRectangle(cornerRadius: Chess.Radius.chip,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.chip,
                                 style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - View model

@Observable
@MainActor
final class GameReviewDetailViewModel {

    struct MovePair { let number: Int; let white: MoveEntry?; let black: MoveEntry? }
    struct MoveEntry {
        let san: String           // UCI for now; full SAN later
        let quality: MoveQuality?
    }
    struct ClassificationBadge {
        let quality: MoveQuality
        let color: Color
        let detail: String?
    }

    // Game + analysis state
    let game: LichessGame
    let username: String
    private(set) var loadedMoves: [Move] = []
    private(set) var positionsByPly: [Position] = [.standardStart]
    private(set) var moves: [MoveAnalysis] = []
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var totalPlies: Int = 0

    // Navigation state
    /// -1 = starting position before any moves played. 0…N-1 = position
    /// AFTER playing move N (so currentPly==0 shows post-1.e4).
    var currentPly: Int = -1
    var isAutoPlaying = false

    private var task: Task<Void, Never>?
    private var autoPlayTask: Task<Void, Never>?
    private var analyzer: GameAnalyzer?
    private let service = LichessService()

    init(game: LichessGame, username: String) {
        self.game = game
        self.username = username
        // Optimistic move count from list-fetch; refined once we
        // fetch the full game.
        let preview = (game.moves ?? "").split(separator: " ")
        totalPlies = preview.count
    }

    // MARK: - Derived UI state

    var currentPosition: Position {
        let idx = currentPly + 1
        guard idx >= 0, idx < positionsByPly.count else { return .standardStart }
        return positionsByPly[idx]
    }

    var playedMoveAtCurrent: Move? {
        guard currentPly >= 0, currentPly < loadedMoves.count else { return nil }
        return loadedMoves[currentPly]
    }

    /// Engine's preferred move at the position *before* `currentPly`.
    /// This is the move the analyzer thought was best — drawn in green.
    var bestMoveAtCurrent: Move? {
        guard currentPly >= 0, currentPly < moves.count,
              let bestUCI = moves[currentPly].topLines.first?.uci
        else { return nil }
        return Move(uci: bestUCI)
    }

    var currentLines: [AnalysisLine] {
        guard currentPly >= 0, currentPly < moves.count else { return [] }
        return moves[currentPly].topLines
    }

    var currentDepth: Int? { currentLines.isEmpty ? nil : 16 }

    var openingForCurrentPly: String? {
        guard currentPly >= 0, currentPly < moves.count else { return nil }
        return moves[currentPly].bookOpening
    }

    var currentClassificationBadge: ClassificationBadge? {
        guard currentPly >= 0, currentPly < moves.count else { return nil }
        let m = moves[currentPly]
        let detail: String?
        if m.quality == .book {
            detail = m.bookOpening
        } else if m.winPercentLoss >= 0.5 {
            detail = String(format: "−%.1f%% win", m.winPercentLoss)
        } else {
            detail = nil
        }
        return ClassificationBadge(
            quality: m.quality,
            color: badgeColor(m.quality),
            detail: detail
        )
    }

    /// White's expected-score at `currentPly`, derived from the
    /// analyzer's evaluation. Defaults to 50 (equal) when no
    /// classification is loaded yet.
    var currentWinPercent: Double {
        guard currentPly >= 0, currentPly < moves.count else { return 50 }
        let m = moves[currentPly]
        // bestScoreCp is from the mover's POV. Convert to White POV.
        let whiteCp = m.mover == .white ? m.bestScoreCp : -m.bestScoreCp
        return GameAnalyzer.winPercent(fromCp: whiteCp)
    }

    var plyLabel: String {
        let total = max(totalPlies, loadedMoves.count)
        return total > 0
            ? "\(currentPly + 1) / \(total)"
            : "0 / 0"
    }

    var progressLabel: String {
        "Analysing \(moves.count) / \(max(totalPlies, loadedMoves.count))"
    }

    var movePairs: [MovePair] {
        var pairs: [MovePair] = []
        let count = max(loadedMoves.count, moves.count)
        var i = 0
        while i < count {
            let white = entry(at: i)
            let black = i + 1 < count ? entry(at: i + 1) : nil
            pairs.append(MovePair(number: i / 2 + 1, white: white, black: black))
            i += 2
        }
        return pairs
    }

    private func entry(at ply: Int) -> MoveEntry? {
        let san = ply < loadedMoves.count ? loadedMoves[ply].uci : ""
        let q = ply < moves.count ? moves[ply].quality : nil
        return MoveEntry(san: san, quality: q)
    }

    // MARK: - Navigation

    func stepForward() {
        let total = loadedMoves.count
        guard currentPly + 1 < total else { return }
        currentPly += 1
    }

    func stepBack() {
        guard currentPly >= 0 else { return }
        currentPly -= 1
    }

    func goToStart() { currentPly = -1; stopAutoPlay() }
    func goToEnd() {
        currentPly = loadedMoves.count - 1
        stopAutoPlay()
    }

    func goTo(ply: Int) {
        guard ply >= -1, ply < loadedMoves.count else { return }
        currentPly = ply
        stopAutoPlay()
    }

    func toggleAutoPlay() {
        if isAutoPlaying { stopAutoPlay() } else { startAutoPlay() }
    }

    private func startAutoPlay() {
        guard !isAutoPlaying else { return }
        isAutoPlaying = true
        autoPlayTask = Task { @MainActor [weak self] in
            while let self, self.isAutoPlaying,
                  self.currentPly + 1 < self.loadedMoves.count {
                try? await Task.sleep(for: .milliseconds(900))
                if Task.isCancelled || !self.isAutoPlaying { break }
                self.stepForward()
            }
            self?.isAutoPlaying = false
        }
    }

    private func stopAutoPlay() {
        isAutoPlaying = false
        autoPlayTask?.cancel()
        autoPlayTask = nil
    }

    // MARK: - Loading

    func start() async {
        guard task == nil, !isRunning else { return }
        errorMessage = nil

        // Step 1: ensure we have the moves. The home-screen list fetches
        // games without the move text (lighter NDJSON), so resolve via
        // the single-game endpoint when needed.
        var fullMoves = game.moves ?? ""
        if fullMoves.isEmpty {
            do {
                await service.authenticate(token: nil)
                let full = try await service.fetchGame(id: game.id)
                fullMoves = full.moves ?? ""
            } catch {
                errorMessage = "Couldn't load game moves: \(error.localizedDescription)"
                return
            }
        }

        let uciTokens = fullMoves.split(separator: " ").map(String.init)
        let parsed = uciTokens.compactMap { Move(uci: $0) }
        guard !parsed.isEmpty else {
            errorMessage = "This game has no moves."
            return
        }
        loadedMoves = parsed
        totalPlies = parsed.count

        // Pre-compute all positions so navigation is instant. Rules
        // engine takes care of castling / en-passant / promotion.
        let rules = ChessKitRulesEngine()
        var positions: [Position] = [.standardStart]
        for m in parsed {
            do {
                positions.append(try rules.apply(m, to: positions.last!))
            } catch {
                positions.append(positions.last!)
            }
        }
        positionsByPly = positions

        // Step 2: run the analyzer in the background.
        isRunning = true
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
                // keep partial results
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRunning = false
            await analyzer.shutdown()
            self.task = nil
        }
    }

    func cancel() {
        stopAutoPlay()
        task?.cancel()
        task = nil
        let analyzer = self.analyzer
        Task { await analyzer?.shutdown() }
        isRunning = false
    }

    private func badgeColor(_ q: MoveQuality) -> Color {
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
}
