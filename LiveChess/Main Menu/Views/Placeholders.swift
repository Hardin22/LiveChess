// Views/Placeholders.swift
// Placeholder views for sections not yet implemented.
// These are "coming soon" screens that compile and run correctly.
// Replace each with the real implementation as you build them out.

import SwiftUI

// MARK: - Reusable Placeholder
// Generic placeholder with an icon, title, and description.
struct ComingSoonView: View {
    let icon: String
    let title: String
    let description: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(accentColor.gradient)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }
}

// MARK: - Lichess Sign-in Gate
// Wraps a placeholder/feature in a guard: when the user is signed out
// it swaps in a "Sign in with Lichess" CTA; otherwise it renders the
// gated content unchanged.
struct LichessGate<Gated: View>: View {
    let icon: String
    let title: String
    let signedOutMessage: String
    let accentColor: Color
    @ViewBuilder let gated: () -> Gated

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.lichess.isSignedIn {
            gated()
        } else {
            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: icon)
                        .font(.system(size: 44))
                        .foregroundStyle(accentColor.gradient)
                }

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(signedOutMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Button {
                    Task { await appModel.lichess.signIn() }
                } label: {
                    Label("Sign in with Lichess", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(minWidth: 240)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(appModel.lichess.status == .signingIn)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassBackgroundEffect()
        }
    }
}

// MARK: - Section Placeholders
// Each Lichess-dependent section wraps a "coming soon" body inside a
// `LichessGate` so unauthenticated users see a friendly sign-in CTA
// instead of a teaser they can't actually use.

struct PuzzlesPlaceholderView: View {
    var body: some View {
        LichessGate(
            icon: "puzzlepiece.fill",
            title: "Puzzles",
            signedOutMessage: "Sign in with Lichess to unlock thousands of puzzles tailored to your rating.",
            accentColor: .purple
        ) {
            ComingSoonView(
                icon: "puzzlepiece.fill",
                title: "Puzzles",
                description: "Sharpen your tactics with thousands of puzzles from real Lichess games.",
                accentColor: .purple
            )
        }
        .navigationTitle("Puzzles")
    }
}

struct GameReviewPlaceholderView: View {
    var body: some View {
        LichessGate(
            icon: "magnifyingglass.circle.fill",
            title: "Game Review",
            signedOutMessage: "Sign in with Lichess to review your games with Stockfish-powered analysis.",
            accentColor: .blue
        ) {
            ComingSoonView(
                icon: "magnifyingglass.circle.fill",
                title: "Game Review",
                description: "Analyze your recent games with Stockfish-powered computer analysis.",
                accentColor: .blue
            )
        }
        .navigationTitle("Game Review")
    }
}

struct HistoryPlaceholderView: View {
    var body: some View {
        LichessGate(
            icon: "clock.fill",
            title: "Game History",
            signedOutMessage: "Sign in with Lichess to browse and filter your past games.",
            accentColor: .orange
        ) {
            ComingSoonView(
                icon: "clock.fill",
                title: "Game History",
                description: "Browse and filter all your past games with full statistics.",
                accentColor: .orange
            )
        }
        .navigationTitle("History")
    }
}

/// Profile is rendered as a real card when the user is signed in (their
/// account snapshot from `LichessSession`); otherwise the gate prompts
/// for sign-in.
struct ProfilePlaceholderView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        LichessGate(
            icon: "person.fill",
            title: "Profile",
            signedOutMessage: "Sign in with Lichess to see your rating history, ratings across speeds, and stats.",
            accentColor: .teal
        ) {
            if let account = appModel.lichess.account {
                ProfileCardView(account: account)
            } else {
                ComingSoonView(
                    icon: "person.fill",
                    title: "Profile",
                    description: "Loading your Lichess profile…",
                    accentColor: .teal
                )
            }
        }
        .navigationTitle("Profile")
    }
}

/// Compact Lichess profile readout: avatar, name, per-speed rating chips,
/// sign-out affordance. Pulled straight from the session's
/// `LichessAccount` so it auto-refreshes when bootstrap or sign-in
/// completes.
private struct ProfileCardView: View {
    let account: LichessAccount
    @Environment(AppModel.self) private var appModel

    private static let displayedPerfs: [(key: String, label: String)] = [
        ("bullet", "Bullet"),
        ("blitz", "Blitz"),
        ("rapid", "Rapid"),
        ("classical", "Classical")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Avatar + name
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.teal.gradient)
                            .frame(width: 96, height: 96)
                        Text(String(account.username.prefix(1)).uppercased())
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    HStack(spacing: 6) {
                        if let title = account.title {
                            Text(title)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        Text(account.username)
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.top, 24)

                // Per-speed rating chips
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                          spacing: 12) {
                    ForEach(Self.displayedPerfs, id: \.key) { entry in
                        ratingChip(label: entry.label, key: entry.key)
                    }
                }
                .padding(.horizontal, 24)

                // Sign-out
                Button(role: .destructive) {
                    Task { await appModel.lichess.signOut() }
                } label: {
                    Label("Sign out of Lichess", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: 280)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .padding(.top, 12)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func ratingChip(label: String, key: String) -> some View {
        let rating = account.rating(forPerfKey: key)
        let games = account.perfs?[key]?.games
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(rating.map { "\($0)" } ?? "—")
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
            Text(games.map { "\($0) games" } ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Settings doesn't depend on Lichess — leave it as a plain coming-soon.
struct SettingsPlaceholderView: View {
    var body: some View {
        ComingSoonView(
            icon: "gearshape.fill",
            title: "Settings",
            description: "Configure your board theme, piece style, language, and Lichess account.",
            accentColor: .gray
        )
        .navigationTitle("Settings")
    }
}

/// Notifications — shown when the user taps the bell icon in the sidebar footer.
/// Replace the ComingSoonView body with the real implementation when ready.
struct NotificationsPlaceholderView: View {
    var body: some View {
        LichessGate(
            icon: "bell.fill",
            title: "Notifications",
            signedOutMessage: "Sign in with Lichess to see your notifications.",
            accentColor: .indigo
        ) {
            ComingSoonView(
                icon: "bell.fill",
                title: "Notifications",
                description: "Challenges, game alerts, and messages from Lichess will appear here.",
                accentColor: .indigo
            )
        }
        .navigationTitle("Notifications")
    }
}
