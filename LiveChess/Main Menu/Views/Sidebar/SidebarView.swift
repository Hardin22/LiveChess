// Views/Sidebar/SidebarView.swift
// The left navigation panel.
// Uses visionOS .glassBackgroundEffect() and hover effects.

import SwiftUI

struct SidebarView: View {

    // The ViewModel is passed in (not @Environment) so the Sidebar
    // can directly drive navigation state.
    @Bindable var viewModel: HomeViewModel

    /// Lichess session — drives the profile footer + sign-in button.
    @Environment(AppModel.self) private var appModel

    var body: some View {
        List(selection: $viewModel.selectedDestination) {

            // MARK: - Game section
            Section {
                // Play with three sub-modes — wired straight to the
                // existing LobbyView via specific destinations so each
                // sub-item lands in the right card.
                DisclosureGroup(isExpanded: $viewModel.isPlayExpanded) {
                    NavigationLink(value: AppDestination.playOnline) {
                        Label("Online Game", systemImage: "globe")
                            .font(.subheadline)
                    }
                    NavigationLink(value: AppDestination.playLocal) {
                        Label("Local Game", systemImage: "person.2.fill")
                            .font(.subheadline)
                    }
                    NavigationLink(value: AppDestination.playBot) {
                        Label("Play with Bot", systemImage: "cpu")
                            .font(.subheadline)
                    }
                } label: {
                    SidebarRowLabel(
                        title: "Play",
                        systemImage: "play.circle.fill",
                        color: .green
                    )
                }
            } header: {
                Text("Game")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // MARK: - Learn Section
            Section("Learn") {
                NavigationLink(value: AppDestination.puzzles) {
                    SidebarRowLabel(
                        title: "Puzzles",
                        systemImage: "puzzlepiece.fill",
                        color: .purple
                    )
                }

                NavigationLink(value: AppDestination.gameReview) {
                    SidebarRowLabel(
                        title: "Game Review",
                        systemImage: "magnifyingglass.circle.fill",
                        color: .blue
                    )
                }
            }

            // MARK: - Account Section
            Section("Account") {
                NavigationLink(value: AppDestination.history) {
                    SidebarRowLabel(
                        title: "History",
                        systemImage: "clock.fill",
                        color: .orange
                    )
                }

                NavigationLink(value: AppDestination.profile) {
                    SidebarRowLabel(
                        title: "Profile",
                        systemImage: "person.fill",
                        color: .teal
                    )
                }

                NavigationLink(value: AppDestination.settings) {
                    SidebarRowLabel(
                        title: "Settings",
                        systemImage: "gearshape.fill",
                        color: .gray
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .glassBackgroundEffect()
        .safeAreaInset(edge: .bottom) {
            SidebarProfileView()
                .padding()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("ChessVision")
                        .font(.headline)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Sidebar Row Label
// Reusable component for each navigation row.
// Includes the colored icon, title, and optional badge.
struct SidebarRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var badge: Int? = nil

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))

            Text(title)
                .font(.callout)

            Spacer()

            if let badge = badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
        .hoverEffect(.lift)
    }
}

// MARK: - Sidebar Profile Footer
// Reflects `LichessSession` state — shows real account when signed in,
// "Guest" + sign-in CTA otherwise. Tap signs out / in respectively.
struct SidebarProfileView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        switch appModel.lichess.status {
        case .unknown:
            profileShell(initial: "?", color: .gray) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Checking…")
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }

        case .signedOut:
            Button {
                Task { await appModel.lichess.signIn() }
            } label: {
                profileShell(initial: "?", color: .gray) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guest")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("Tap to sign in with Lichess")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)

        case .signingIn:
            profileShell(initial: "…", color: .gray) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signing in…")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("Lichess")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .signingOut:
            profileShell(initial: "…", color: .gray) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signing out…")
                        .font(.callout)
                        .fontWeight(.medium)
                }
            }

        case .signedIn(let account):
            Menu {
                Button(role: .destructive) {
                    Task { await appModel.lichess.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                profileShell(
                    initial: String(account.username.prefix(1)).uppercased(),
                    color: .green
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let title = account.title {
                                Text(title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                            Text(account.username)
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            if let rating = account.rating(forPerfKey: "rapid") {
                                Text("Online · \(rating)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Online")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .hoverEffect(.lift)

        case .error(let message):
            Button {
                Task { await appModel.lichess.bootstrap() }
            } label: {
                profileShell(initial: "!", color: .orange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lichess error")
                            .font(.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
        }
    }

    /// Shared row chrome: avatar circle + content. Keeps each status
    /// branch a one-liner of layout.
    @ViewBuilder
    private func profileShell<Content: View>(
        initial: String,
        color: Color,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 38, height: 38)
                Text(initial)
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
            content()
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
