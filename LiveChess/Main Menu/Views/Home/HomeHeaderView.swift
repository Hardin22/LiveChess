// Views/Home/HomeHeaderView.swift
// Top section of the Home screen.
// Shows: welcome message, key stats, search bar.

import SwiftUI

struct HomeHeaderView: View {
    
    @Bindable var viewModel: HomeViewModel
    
    // Controls the subtle entry animation
    @State private var isVisible = false
    
    var body: some View {
        HStack(alignment: .top, spacing: Chess.Space.l) {

            // LEFT: brand wordmark + tagline + stats chips
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                VStack(alignment: .leading, spacing: 6) {
                    BrandMark(.wordmark(size: 38))
                    Text(viewModel.isSignedIn
                         ? "Welcome back, \(viewModel.displayUsername)"
                         : Chess.Brand.tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isSignedIn {
                    HStack(spacing: Chess.Space.xs) {
                        StatChipView(
                            icon: "trophy.fill",
                            value: viewModel.displayRating > 0 ? "\(viewModel.displayRating)" : "—",
                            label: "rapid",
                            color: Chess.Palette.bronze
                        )
                        if let games = viewModel.displayGamesPlayed, games > 0 {
                            StatChipView(
                                icon: "square.grid.3x3.fill",
                                value: "\(games)",
                                label: "games",
                                color: Chess.Palette.bronze
                            )
                        }
                    }
                }
            }

            Spacer()

            SearchBarView(text: $viewModel.searchText)
                .frame(maxWidth: 240)
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 16)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                isVisible = true
            }
        }
    }
}

// MARK: - Stat Chip
// A pill-shaped stat indicator: icon + value + label
struct StatChipView: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            
            Text(value)
                .font(.callout)
                .fontWeight(.semibold)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // visionOS glass material for the chip background
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .hoverEffect(.lift)
    }
}

// MARK: - Search Bar
// visionOS-style floating search input
struct SearchBarView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            
            // The actual text field
            TextField("Search games, openings...", text: $text)
                .font(.callout)
                .focused($isFocused)
                .submitLabel(.search)
            
            // Clear button appears when there's text
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                // Border glows slightly when focused
                .strokeBorder(isFocused ? .white.opacity(0.3) : .white.opacity(0.1), lineWidth: 0.5)
        )
        // visionOS: hover effect makes it slightly lift when the user looks at it
        .hoverEffect(.highlight)
    }
}

#Preview {
    HomeHeaderView(viewModel: HomeViewModel())
        .padding()
}
