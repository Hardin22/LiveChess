import SwiftUI

/// Centralised design tokens for Chess+ on visionOS.
///
/// Goals:
///   * Lean into Liquid Glass — favour `.thinMaterial` / `.ultraThinMaterial`
///     over solid colours so depth and translucency stay correct against
///     passthrough.
///   * Restrained palette — neutrals + ONE accent (a chess.com-leaning
///     warm green) + ONE highlight (warm amber for accuracy / brilliancy
///     flourishes). No rainbow status colours except where genuinely
///     diagnostic (review classifications).
///   * A consistent spacing/radius/typography scale so every surface
///     reads as part of the same product — not a stack of feature
///     pages designed independently.
///
/// Use these tokens (not literals) anywhere you'd otherwise reach for
/// raw values. If you find yourself adding a new shade or radius, ask
/// whether an existing token would do.
enum Chess {

    // MARK: - Brand

    /// Display name + standard tagline pair used across hero surfaces.
    enum Brand {
        static let name = "Chess+"
        static let tagline = "Play, learn, and review — in mixed reality."
    }

    // MARK: - Palette

    enum Palette {
        /// Monochrome accent — pure white. The brand identity is
        /// "no colour": selection state = lighter material + bolder
        /// text, primary action = bordered glass pill with crisp
        /// white text. Reads as Apple-system premium and never
        /// fights the gold / wood / marble piece previews or the
        /// passthrough room behind a glass surface.
        ///
        /// All `accent.opacity(X)` call sites become "white at X
        /// opacity" which is exactly what you want for a tinted
        /// selection state on a dark canvas.
        ///
        /// `highlight` + `info` aliased to `accent` so older call
        /// sites keep building. Don't introduce a new hue for
        /// emphasis — use type weight or material elevation.
        static let accent       = Color.white
        static let highlight    = accent
        static let info         = accent

        /// Warm cream sampled from the app icon's light marble.
        /// Used as a tint behind selection-state fills so chips read as
        /// "lit marble" rather than plain Apple glass. Don't use as a
        /// text colour — too low contrast on translucent surfaces.
        static let cream  = Color(red: 0.929, green: 0.901, blue: 0.831)

        /// Warm bronze sampled from the king's highlights in the app
        /// icon. Reserved for the brand "+" wordmark, selected-state
        /// strokes, and rare flourishes (accuracy %, brilliant !!).
        /// Pure white still owns the general accent role.
        static let bronze = Color(red: 0.769, green: 0.647, blue: 0.455)

        /// Material fill behind cards — wraps `Material` so we can
        /// swap globally if the depth balance ever changes.
        static let cardMaterial: Material = .regularMaterial
        static let chromeMaterial: Material = .thinMaterial
    }

    // MARK: - Spacing scale (4-pt grid, doubled at the top)

    enum Space {
        /// 4. Hairline gaps inside a label.
        static let xxs: CGFloat = 4
        /// 8. Between an icon and its label.
        static let xs:  CGFloat = 8
        /// 12. Between rows of related controls.
        static let s:   CGFloat = 12
        /// 16. Between cards.
        static let m:   CGFloat = 16
        /// 24. Between sections.
        static let l:   CGFloat = 24
        /// 32. Page-level padding.
        static let xl:  CGFloat = 32
        /// 48. Hero margin.
        static let xxl: CGFloat = 48
    }

    // MARK: - Corner radius scale

    enum Radius {
        /// 8 — small badges / chips.
        static let chip:  CGFloat = 8
        /// 14 — inline rows.
        static let row:   CGFloat = 14
        /// 20 — cards.
        static let card:  CGFloat = 20
        /// 28 — hero surfaces.
        static let hero:  CGFloat = 28
    }

    // MARK: - Typography

    enum Typography {
        /// Big numeric eyebrow (e.g. accuracy %).
        static func eyebrow() -> Font {
            .system(size: 12, weight: .semibold, design: .rounded)
                .smallCaps()
        }
        /// Brand wordmark — used once per hero surface.
        static func brand(size: CGFloat = 42) -> Font {
            .system(size: size, weight: .semibold, design: .serif)
        }
        /// Section / card title.
        static func sectionTitle() -> Font {
            .system(.title3, design: .default).weight(.semibold)
        }
        /// Row primary text.
        static func rowTitle() -> Font {
            .system(.callout).weight(.medium)
        }
        /// Row secondary text.
        static func rowDetail() -> Font {
            .system(.caption)
        }
    }
}

// MARK: - Card primitives

/// Single elevated card surface used across the app. Wrap content in
/// this instead of hand-rolling a background + corner radius + border
/// every time — keeps the chrome consistent.
struct ChessCard<Content: View>: View {
    enum Style {
        /// Standard secondary surface.
        case standard
        /// Higher-emphasis surface for hero CTAs.
        case hero
        /// Compact in-list row.
        case row
    }

    let style: Style
    let content: Content

    init(_ style: Style = .standard, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(material, in: shape)
            // Solid dark tint behind the material so the card stays
            // legible when it sits on top of another translucent
            // surface (e.g. inside a visionOS sheet that's itself
            // .regularMaterial). Without this, card-on-card composites
            // to near-invisible against passthrough.
            .background(Color.black.opacity(0.22), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private var padding: CGFloat {
        switch style {
        case .standard: return Chess.Space.m
        case .hero:     return Chess.Space.l
        case .row:      return Chess.Space.s
        }
    }

    private var material: Material {
        switch style {
        case .hero:     return Chess.Palette.cardMaterial
        case .standard: return Chess.Palette.cardMaterial
        case .row:      return Chess.Palette.chromeMaterial
        }
    }

    private var shape: RoundedRectangle {
        let r: CGFloat
        switch style {
        case .hero:     r = Chess.Radius.hero
        case .standard: r = Chess.Radius.card
        case .row:      r = Chess.Radius.row
        }
        return RoundedRectangle(cornerRadius: r, style: .continuous)
    }
}

/// Small inline chip used for quality labels, status indicators, etc.
struct ChessChip: View {
    let label: String
    let icon: String?
    let tint: Color

    init(_ label: String, icon: String? = nil, tint: Color = Chess.Palette.accent) {
        self.label = label
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.caption2)
            }
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
    }
}

// MARK: - Brand mark

/// Single source of truth for the Chess+ brand mark. Wherever brand
/// identity should appear (home header, lobby header, in-match HUD,
/// sidebar), use one of these two modes instead of hand-rolling a
/// crown.fill + serif text combo:
///
///   * `.wordmark(size:)` — circular app-icon image + serif "Chess"
///     in accent + serif "+" in bronze. The hero treatment.
///   * `.iconOnly(size:)` — circular app-icon image alone. Used
///     where the wordmark would duplicate text already on screen
///     (e.g. the sidebar when the home header is also visible).
///
/// The shared component guarantees that any visual change — bronze
/// shade, font weight, icon swap — propagates everywhere automatically.
struct BrandMark: View {
    enum Style { case wordmark(size: CGFloat); case iconOnly(size: CGFloat) }
    let style: Style

    init(_ style: Style = .wordmark(size: 38)) { self.style = style }

    var body: some View {
        switch style {
        case .wordmark(let size):
            HStack(spacing: max(4, size * 0.18)) {
                logo(size: size * 0.95)
                HStack(spacing: 0) {
                    Text("Chess").foregroundStyle(Chess.Palette.accent)
                    Text("+").foregroundStyle(Chess.Palette.bronze)
                }
                .font(.system(size: size, weight: .semibold, design: .serif))
            }
        case .iconOnly(let size):
            logo(size: size)
        }
    }

    private func logo(size: CGFloat) -> some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // Subtle bronze rim so the circular logo reads as a coin,
            // not a flat decal pasted on glass. Same shape language as
            // the selection chips elsewhere in the UI.
            .overlay(
                Circle().strokeBorder(
                    Chess.Palette.bronze.opacity(0.45),
                    lineWidth: max(0.5, size * 0.012)
                )
            )
            .clipShape(Circle())
    }
}

/// Compact section header used at the top of grouped lists.
struct ChessSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Chess.Typography.sectionTitle())
            if let subtitle {
                Text(subtitle)
                    .font(Chess.Typography.rowDetail())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
