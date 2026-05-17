// Views/Home/HomeFeatureCardsView.swift
// The two large floating cards: "Daily Puzzle" and "Game Review".
// These are the most prominent interactive elements on the home screen.

import SwiftUI

struct HomeFeatureCardsView: View {
    
    let viewModel: HomeViewModel
    @State private var isVisible = false
    
    var body: some View {
        VStack(spacing: Chess.Space.m) {
            // HERO: Quick Play — the primary CTA. Two paths: Local vs Online.
            QuickPlayHeroCard(viewModel: viewModel)

            HStack(spacing: Chess.Space.m) {
                PuzzleLaunchCard(puzzle: viewModel.puzzle)
                GameReviewFeatureCard(
                    game: viewModel.latestGame,
                    username: viewModel.displayUsername
                )
                .onTapGesture { viewModel.navigate(to: .gameReview) }
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2)) {
                isVisible = true
            }
        }
    }
}

// MARK: - Quick Play hero
// The primary entry point on the Home screen. Splits "Play locally vs
// Stockfish" and "Find an online opponent" into two equally-weighted
// CTAs side-by-side, both lifting to the lobby with the right mode
// preselected. Mirrors the way chess.com surfaces "Play" as the
// dominant home action rather than burying it behind a tab switch.
private struct QuickPlayHeroCard: View {
    let viewModel: HomeViewModel

    var body: some View {
        ChessCard(.hero) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                HStack(spacing: Chess.Space.s) {
                    iconBadge("play.fill", tint: Chess.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play")
                            .font(Chess.Typography.sectionTitle())
                        Text("Jump into a match — your room or a virtual environment.")
                            .font(Chess.Typography.rowDetail())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: Chess.Space.s) {
                    QuickPlayChoice(
                        title: "Local match",
                        subtitle: "Vs. Stockfish 17",
                        icon: "cpu",
                        tint: Chess.Palette.accent
                    ) { viewModel.navigate(to: .playLocal) }

                    QuickPlayChoice(
                        title: "Online",
                        subtitle: "Find a Lichess opponent",
                        icon: "globe",
                        tint: Chess.Palette.accent
                    ) { viewModel.navigate(to: .playOnline) }
                }
            }
        }
    }

    @ViewBuilder
    private func iconBadge(_ name: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: 38, height: 38)
            Image(systemName: name)
                .foregroundStyle(tint)
                .font(.callout)
        }
    }
}

private struct QuickPlayChoice: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Chess.Typography.rowTitle())
                    Text(subtitle)
                        .font(Chess.Typography.rowDetail())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(Chess.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }
}

// MARK: - Puzzle launch card
// Wraps the existing PuzzleFeatureCard with an onTapGesture that
// constructs a PuzzleSession from the daily puzzle and opens the
// immersive 3-D board to solve it on the real chess set rather
// than punting to the placeholder list screen.
@MainActor
private struct PuzzleLaunchCard: View {
    let puzzle: LichessPuzzle?
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var isLaunching = false

    var body: some View {
        PuzzleFeatureCard(puzzle: puzzle)
            .opacity(isLaunching ? 0.6 : 1)
            .overlay {
                if isLaunching {
                    ProgressView().tint(Chess.Palette.accent)
                }
            }
            .onTapGesture {
                guard !isLaunching, let p = puzzle else { return }
                Task { await launch(p) }
            }
    }

    private func launch(_ puzzle: LichessPuzzle) async {
        isLaunching = true
        defer { isLaunching = false }
        guard let session = PuzzleSession(puzzle: puzzle) else { return }
        appModel.activeSession = .puzzle(session)
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        default:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
        }
    }
}

// MARK: - Puzzle Feature Card
struct PuzzleFeatureCard: View {
    let puzzle: LichessPuzzle?
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                
                // Card header row
                HStack {
                    // Icon with colored background
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Chess.Palette.accent.opacity(0.20))
                            .frame(width: 36, height: 36)
                        Image(systemName: "puzzlepiece.fill")
                            .foregroundStyle(Chess.Palette.accent)
                            .font(.callout)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily Puzzle")
                            .font(.callout)
                            .fontWeight(.semibold)
                        
                        if let rating = puzzle?.puzzle.rating {
                            Text("Rating: \(rating)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Rating: —")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Mini chess board preview (decorative)
                    MiniChessBoardView()
                        .frame(width: 70, height: 70)
                }
                
                // Stats row
                HStack(spacing: 8) {
                    MiniStatTag(label: "Streak", value: "7")
                    MiniStatTag(label: "Solved", value: "12")
                    if let themes = puzzle?.puzzle.themes.first {
                        MiniStatTag(label: "Theme", value: themes.capitalized)
                    }
                }
                
                // CTA Button
                FeatureCardButton(
                    title: "Continue Puzzle",
                    icon: "play.fill",
                    color: Chess.Palette.accent
                )
            }
        }
    }
}

// MARK: - Game Review Feature Card
struct GameReviewFeatureCard: View {
    let game: LichessGame?
    let username: String
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                
                // Card header
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Chess.Palette.accent.opacity(0.20))
                            .frame(width: 36, height: 36)
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Chess.Palette.accent)
                            .font(.callout)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Game Review")
                            .font(.callout)
                            .fontWeight(.semibold)
                        
                        if let opponent = game?.opponent(for: username) {
                            Text("vs \(opponent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Last game")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    MiniChessBoardView(variant: .review)
                        .frame(width: 70, height: 70)
                }
                
                // Stats
                HStack(spacing: 8) {
                    if let acc = game?.accuracy(for: username) {
                        MiniStatTag(label: "Accuracy", value: String(format: "%.0f%%", acc))
                    } else {
                        MiniStatTag(label: "Accuracy", value: "—")
                    }
                    
                    // Blunder count from analysis (if available)
                    MiniStatTag(label: "Blunders", value: "2")
                    MiniStatTag(label: "Moves", value: game.map { "\($0.moveCount)" } ?? "—")
                }
                
                FeatureCardButton(
                    title: "Review Game",
                    icon: "eye.fill",
                    color: Chess.Palette.accent
                )
            }
        }
    }
}

// MARK: - Supporting Components

// Generic glass card container
// Other cards can reuse this for consistent styling
struct GlassCard<Content: View>: View {
    let content: () -> Content
    
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    
    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
            // visionOS: lift effect on hover (gaze-based interaction)
            .hoverEffect(.lift)
    }
}

// Small tag showing a label + value pair
struct MiniStatTag: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

// Tappable CTA button at the bottom of feature cards
struct FeatureCardButton: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Mini Chess Board
// A decorative 4x4 chessboard pattern with chess piece emojis.
// NOT a real chess engine — purely visual decoration.
enum MiniBoardVariant { case puzzle, review }

struct MiniChessBoardView: View {
    var variant: MiniBoardVariant = .puzzle
    
    // Different piece positions for puzzle vs review
    private var layout: [(Bool, String?)] {
        switch variant {
        case .puzzle:
            return [
                (true, "♚"), (false, nil), (true, nil), (false, "♜"),
                (false, nil), (true, nil), (false, "♟"), (true, nil),
                (true, nil), (false, "♙"), (true, nil), (false, nil),
                (false, "♔"), (true, nil), (false, nil), (true, "♕")
            ]
        case .review:
            return [
                (false, nil), (true, "♞"), (false, "♛"), (true, nil),
                (true, "♜"), (false, nil), (true, nil), (false, "♝"),
                (false, "♙"), (true, nil), (false, "♗"), (true, nil),
                (true, nil), (false, "♔"), (true, "♖"), (false, nil)
            ]
        }
    }
    
    var body: some View {
        // 4x4 grid of squares
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4),
            spacing: 0
        ) {
            ForEach(layout.indices, id: \.self) { index in
                let (isLight, piece) = layout[index]
                ZStack {
                    // Square color
                    Rectangle()
                        .fill(isLight ? Color(red: 0.94, green: 0.85, blue: 0.71) : Color(red: 0.71, green: 0.53, blue: 0.39))
                    
                    // Piece emoji if present
                    if let piece = piece {
                        Text(piece)
                            .font(.system(size: 11))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

#Preview {
    HomeFeatureCardsView(viewModel: HomeViewModel())
        .padding()
}
