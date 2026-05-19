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
                    // Rating strip: one chip per supported Lichess perf
                    // (Rapid, Classical, Correspondence, Puzzles). Bullet
                    // and Blitz are deliberately omitted — those time
                    // controls aren't playable in the app, so a rating
                    // the user can't act on is just noise.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Chess.Space.xs) {
                            ForEach(viewModel.displayedRatings) { row in
                                RatingChipView(row: row)
                            }
                        }
                    }
                    .scrollClipDisabled()
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

// MARK: - Rating Chip
// Lichess-perf-specific chip: icon + rating + perf label (and a tiny
// "?" badge for provisional ratings). Shows "—" when the user has no
// rating for that perf so the row keeps a stable layout.
struct RatingChipView: View {
    let row: LichessAccount.RatingRow

    private var ratingText: String {
        guard let r = row.rating else { return "—" }
        return String(r)   // ungrouped — chess convention ("1500" not "1,500")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.icon)
                .font(.caption)
                .foregroundStyle(Chess.Palette.bronze)

            Text(ratingText)
                .font(.callout.monospacedDigit())
                .fontWeight(.semibold)

            Text(row.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .hoverEffect(.lift)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let r = row.rating.map(String.init) ?? "no rating"
        let prov = row.provisional ? " provisional" : ""
        return "\(row.label) rating: \(r)\(prov)"
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
