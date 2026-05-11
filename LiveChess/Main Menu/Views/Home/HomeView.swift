// Views/Home/HomeView.swift
// The main content area displayed when "Home" is selected in the sidebar.
// Uses a ScrollView with floating glass cards.

import SwiftUI

struct HomeView: View {
    
    @Bindable var viewModel: HomeViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                
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
        // Refresh gesture (pull down)
        .refreshable {
            await viewModel.refreshAll()
        }
        // visionOS: Adds glass background to the entire content area
        .glassBackgroundEffect()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .hoverEffect(.lift)
            }
        }
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
