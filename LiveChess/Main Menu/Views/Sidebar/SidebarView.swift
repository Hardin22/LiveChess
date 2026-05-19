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
                // Play with two sub-modes (bot removed)
                DisclosureGroup(isExpanded: $viewModel.isPlayExpanded) {
                    NavigationLink(value: AppDestination.playOnline) {
                        Label("Online Game", systemImage: "globe")
                            .font(.subheadline)
                    }
                    NavigationLink(value: AppDestination.playLocal) {
                        Label("Local Game", systemImage: "person.2.fill")
                            .font(.subheadline)
                    }
                    // "Play with Bot" intentionally removed
                } label: {
                    SidebarRowLabel(
                        title: "Play",
                        systemImage: "play.circle.fill",
                        color: Chess.Palette.bronze
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
                        color: Chess.Palette.bronze
                    )
                }
                NavigationLink(value: AppDestination.gameReview) {
                    SidebarRowLabel(
                        title: "Game Review",
                        systemImage: "magnifyingglass.circle.fill",
                        color: Chess.Palette.bronze
                    )
                }
            }

            // MARK: - Account Section
            // Profile and Settings removed here — they live in the footer card below.
            Section("Account") {
                NavigationLink(value: AppDestination.history) {
                    SidebarRowLabel(
                        title: "History",
                        systemImage: "clock.fill",
                        color: Chess.Palette.bronze
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .glassBackgroundEffect()
        .safeAreaInset(edge: .bottom) {
            // Pass viewModel so the footer can trigger navigation.
            // Horizontal inset is zero — the outer `.padding(.horizontal)`
            // on the List below already insets us to match the list rows.
            SidebarProfileView(viewModel: viewModel)
                .padding(.bottom, 12)
        }
        .padding(.horizontal)
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
                // White icon on a translucent backdrop — the old
                // `color.gradient` is now a solid white fill after
                // the monochrome theme switch, which would make the
                // white glyph invisible.
                .background(.thinMaterial,
                            in: RoundedRectangle(cornerRadius: 7))

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
// Shows a compact card at the bottom of the sidebar.
//
// When signed in, the card has three zones:
//   [Avatar]  [Name + rating]  [Spacer]  [🔔]  [⚙️]
//
// Tapping the avatar/name area navigates to Profile.
// Tapping 🔔 navigates to Notifications.
// Tapping ⚙️ navigates to Settings.
//
// Other states (guest, loading, error) show a simpler row as before.
struct SidebarProfileView: View {
    @Environment(AppModel.self) private var appModel

    // Needed to call viewModel.navigate(to:) for Profile / Settings / Notifications
    @Bindable var viewModel: HomeViewModel

    var body: some View {
        switch appModel.lichess.status {

        // `.unknown` means bootstrap hasn't resolved yet. Rather than
        // leave the user staring at "Checking…", surface the same
        // Guest / Sign-in CTA — if bootstrap finds a valid token the
        // view will flip to `.signedIn` and re-render automatically.
        case .unknown, .signedOut:
            Button {
                Task { await appModel.lichess.signIn() }
            } label: {
                profileShell(initial: "?", color: .gray) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guest")
                            .font(.callout)
                            .fontWeight(.medium)
                        connectionStatusLine(isOnline: false, detail: "Tap to sign in with Lichess")
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
                Text("Signing out…")
                    .font(.callout)
                    .fontWeight(.medium)
            }

        case .signedIn(let account):
            // ── The redesigned card ──────────────────────────────────
            ChessCard(.row) {
                HStack(spacing: Chess.Space.s) {
                    Button {
                        viewModel.navigate(to: .profile)
                    } label: {
                        HStack(spacing: Chess.Space.s) {
                            ZStack {
                                Circle()
                                    .fill(.thinMaterial)
                                    .frame(width: 38, height: 38)
                                Text(String(account.username.prefix(1)).uppercased())
                                    .font(.callout)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if let title = account.title {
                                        Text(title)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Chess.Palette.highlight)
                                    }
                                    Text(account.username)
                                        .font(Chess.Typography.rowTitle())
                                        .lineLimit(1)
                                }
                                HStack(spacing: 4) {
                                    // Lichess-style green presence dot —
                                    // ringed with a faint halo so it reads
                                    // against the bronze sidebar surface.
                                    Circle()
                                        .fill(Color(red: 0.30, green: 0.78, blue: 0.36))
                                        .frame(width: 6, height: 6)
                                        .shadow(color: Color(red: 0.30, green: 0.78, blue: 0.36).opacity(0.6),
                                                radius: 2)
                                    if let count = appModel.onlineCount.count {
                                        // Lichess footer-style "Online ·
                                        // 12,345" — global players online
                                        // count pushed over the lobby
                                        // socket. Grouped because tens of
                                        // thousands reads better with a
                                        // separator.
                                        Text("Online · \(Self.formattedCount(count))")
                                            .font(Chess.Typography.rowDetail())
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Online")
                                            .font(Chess.Typography.rowDetail())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.lift)

                    Spacer()

                    footerIconButton("bell.fill") {
                        viewModel.navigate(to: .notifications)
                    }
                    footerIconButton("gearshape.fill") {
                        viewModel.navigate(to: .settings)
                    }
                }
            }
            // ────────────────────────────────────────────────────────

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

    private func connectionStatusLine(isOnline: Bool, detail: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOnline ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
                .shadow(color: isOnline ? .green.opacity(0.55) : .clear, radius: 4, x: 0, y: 0)
            Text(detail)
                .font(Chess.Typography.rowDetail())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Compact icon button reused for the bell + gear in the footer.
    @ViewBuilder
    private func footerIconButton(
        _ systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // Shared chrome for non-signedIn states (guest, loading, error).
    // Keeps those branches to a single call instead of repeating layout code.
    @ViewBuilder
    private func profileShell<Content: View>(
        initial: String,
        color: Color,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
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

    /// Grouped player count, locale-aware ("12,345" in en-US,
    /// "12.345" in it-IT). Used for the global online-players count
    /// in the sidebar — where thousands-grouping aids readability,
    /// unlike chess ratings which are conventionally ungrouped.
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    private static func formattedCount(_ n: Int) -> String {
        countFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
