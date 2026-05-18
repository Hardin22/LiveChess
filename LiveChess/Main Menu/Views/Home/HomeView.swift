// Views/Home/HomeView.swift
// The main content area displayed when "Home" is selected in the sidebar.
// Uses a ScrollView with floating glass cards.

import SwiftUI

struct HomeView: View {

    @Bindable var viewModel: HomeViewModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Guest-only CTA: a second, hard-to-miss sign-in entry
                // point on top of the sidebar footer button.
                if !appModel.lichess.isSignedIn {
                    GuestSignInBanner()
                }

                // MARK: 1. Header + Search
                HomeHeaderView(viewModel: viewModel)

                // MARK: 2. Main Feature Cards (Puzzle + Game Review)
                HomeFeatureCardsView(viewModel: viewModel)

                // MARK: 3. Recent Games List
                HomeGamesListView(viewModel: viewModel)
            }
            .padding(28)
        }
        .scrollIndicators(.hidden)
        // Pull-down still refreshes the page silently — we just don't
        // surface the navigation chrome (title + refresh button) so the
        // home content fills the full surface. The brand wordmark in
        // HomeHeaderView already does the "you are here" job better
        // than a small "Home" title would.
        .refreshable {
            await viewModel.refreshAll()
        }
        .glassBackgroundEffect()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Guest Sign-In Banner

/// Prominent CTA shown in place of the signed-in stats when the user
/// hasn't authenticated with Lichess. Drives the same `signIn()` entry
/// point as the sidebar footer — duplicated here so that the auth flow
/// is reachable from the largest, most visible surface in the app.
private struct GuestSignInBanner: View {
    @Environment(AppModel.self) private var appModel

    private var isSigningIn: Bool {
        if case .signingIn = appModel.lichess.status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Chess.Palette.bronze.gradient.opacity(0.25))
                    .frame(width: 52, height: 52)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(Chess.Palette.bronze)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in with Lichess")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Access your puzzles, game review, and history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await appModel.lichess.signIn() }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                    }
                    Text(isSigningIn ? "Signing in…" : "Sign in")
                        .fontWeight(.semibold)
                }
                .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(isSigningIn)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Chess.Palette.bronze.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Preview
#Preview(windowStyle: .plain) {
    HomeView(viewModel: {
        let vm = HomeViewModel()
        // Inject mock data for preview
        return vm
    }())
}
