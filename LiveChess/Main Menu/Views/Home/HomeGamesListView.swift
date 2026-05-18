// Views/Home/HomeGamesListView.swift
// The "Recent Games" section: a dynamic list of game rows.
// Data comes from the Lichess API (real, not hardcoded).

import SwiftUI

struct HomeGamesListView: View {
    
    let viewModel: HomeViewModel
    @State private var isVisible = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // Section header with "See all" link
            HStack {
                Text("Recent Games")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("See all") {
                    viewModel.navigate(to: .history)
                }
                .font(.callout)
                .foregroundStyle(.green)
                .hoverEffect(.highlight)
            }
            
            // CONTENT: shows loading skeleton, empty state, or game rows
            if viewModel.isLoadingGames {
                // Loading skeleton animation
                VStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        GameRowSkeleton()
                    }
                }
            } else if viewModel.filteredGames.isEmpty {
                GamesEmptyState()
            } else {
                // Real game data from Lichess API
                VStack(spacing: 8) {
                    ForEach(Array(viewModel.filteredGames.prefix(8))) { game in
                        GameRowView(
                            game: game,
                            username: viewModel.displayUsername
                        )
                    }
                }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3)) {
                isVisible = true
            }
        }
    }
}

// MARK: - Game Row
// One row in the recent games list.
struct GameRowView: View {
    let game: LichessGame
    let username: String
    
    // Hover state for visionOS lift effect
    @State private var isHovered = false
    
    private var result: GameResult { game.result(for: username) }
    private var opponent: String { game.opponent(for: username) }
    private var accuracy: Double? { game.accuracy(for: username) }
    
    var body: some View {
        HStack(spacing: 12) {
            
            // RESULT BADGE (W / L / D)
            ResultBadge(result: result)
            
            // GAME INFO
            VStack(alignment: .leading, spacing: 3) {
                // Opponent name
                HStack(spacing: 4) {
                    Text("vs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(opponent)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                
                // Details: time control, moves, opening
                HStack(spacing: 4) {
                    if let clock = game.clock {
                        Text(clock.displayString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("\(game.moveCount) moves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let opening = game.opening?.name {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(opening)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // ACCURACY BAR + VALUE
            if let acc = accuracy {
                VStack(alignment: .trailing, spacing: 3) {
                    // Thin progress bar showing accuracy
                    AccuracyBar(value: acc / 100)
                        .frame(width: 60, height: 4)
                    
                    Text(String(format: "%.1f%%", acc))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            // DATE
            VStack(alignment: .trailing, spacing: 3) {
                Text(game.date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Text(game.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // REVIEW BUTTON — opens the immersive 3-D board with the
            // game pre-loaded for HUD-driven playback. Replaces the
            // earlier 2-D detail screen — the user explicitly asked
            // for review on the same board they play on.
            ReviewLaunchButton(game: game, username: username)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .hoverEffect(.lift)
    }
}

// MARK: - Result Badge (W / L / D circle)
struct ResultBadge: View {
    let result: GameResult
    
    private var color: Color {
        switch result {
        case .win: return .green
        case .loss: return .red
        case .draw: return .yellow
        }
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.2))
                .frame(width: 30, height: 30)
            
            Text(result.shortLabel)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Accuracy Progress Bar
struct AccuracyBar: View {
    let value: Double // 0.0 to 1.0
    
    private var barColor: Color {
        switch value {
        case 0.8...: return .green
        case 0.6..<0.8: return .yellow
        default: return .red
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 99)
                    .fill(.white.opacity(0.1))
                
                // Filled portion
                RoundedRectangle(cornerRadius: 99)
                    .fill(barColor)
                    .frame(width: geo.size.width * max(0, min(1, value)))
                    // Animate when value appears
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
            }
        }
    }
}

// MARK: - Loading Skeleton
// Shown while games are being fetched from the API.
// Uses a shimmer-like animation to indicate loading.
struct GameRowSkeleton: View {
    @State private var opacity: Double = 0.4
    
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.15))
                .frame(width: 30, height: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(width: 140, height: 12)
                Capsule()
                    .fill(.white.opacity(0.1))
                    .frame(width: 200, height: 10)
            }
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        // Pulse animation
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                opacity = 0.9
            }
        }
    }
}

// MARK: - Empty State
// Shown when there are no games to display.
struct GamesEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            
            Text("No recent games")
                .font(.callout)
                .fontWeight(.medium)
            
            Text("Play a game on Lichess to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Review launch button
// Resolves the game's moves (the list endpoint omits them to keep
// NDJSON light), wraps the result in a `ReviewSession`, and opens
// the immersive 3-D board so the user reviews the game on the same
// surface they play on.
@MainActor
private struct ReviewLaunchButton: View {
    let game: LichessGame
    let username: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task { await launchReview() }
        } label: {
            HStack(spacing: 4) {
                if isPreparing {
                    ProgressView().controlSize(.mini)
                }
                Text(isPreparing ? "Loading…" : "Review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(isPreparing)
        .alert(
            "Can't open review",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private func launchReview() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        // Pull the full game (with moves) if we don't already have them.
        // The listing endpoint sends `moves=false` to keep NDJSON light,
        // so essentially every Review click takes this branch.
        var resolved = game
        if (game.moves ?? "").isEmpty {
            let svc = LichessService()
            await svc.authenticate(token: appModel.lichess.token)
            do {
                resolved = try await svc.fetchGame(id: game.id)
            } catch {
                print("[Review] fetchGame failed for \(game.id): \(error)")
                errorMessage = "Couldn't load this game from Lichess.\n\(error.localizedDescription)"
                return
            }
        }

        if (resolved.moves ?? "").isEmpty {
            print("[Review] game \(game.id) has no moves to review")
            errorMessage = "This game has no recorded moves to review."
            return
        }

        guard let session = ReviewSession(game: resolved, username: username) else {
            print("[Review] ReviewSession init failed for \(game.id) — couldn't parse moves: \(resolved.moves ?? "")")
            errorMessage = "Couldn't parse the moves of this game."
            return
        }

        // Hand off to the immersive space the same way local / online
        // play does. `pendingReopen` is left alone so a normal close
        // tears the session down on `onDisappear` of the scene host.
        appModel.activeSession = .review(session)
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        case .userCancelled:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
        case .error:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
            errorMessage = "The immersive space failed to open."
        @unknown default:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
        }
    }
}

#Preview {
    HomeGamesListView(viewModel: HomeViewModel())
        .padding()
}
