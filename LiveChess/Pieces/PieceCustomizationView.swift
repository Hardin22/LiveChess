import SwiftUI

/// Sheet opened from the lobby's "Pieces" button. Lets the user pick a
/// material preset (Plastic, Metal, Wood, Marble, Glass, …) and a
/// custom RGB tint for the white and black sides. Shows a live 3D
/// preview of the chosen combination so judging the look doesn't
/// require opening a real game.
///
/// Persistence is handled by `PieceCustomization`: every change to
/// `appModel.pieceCustomization.current` flushes to UserDefaults
/// transparently. Closing the sheet doesn't roll anything back.
@MainActor
struct PieceCustomizationView: View {

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(AppModel.self) private var appModel

    /// Local state so the user can flip between previewing the white
    /// piece and the black piece without affecting the persisted
    /// material. Starts on white because users usually pick the "main"
    /// colour for white first.
    @State private var previewSide: Side = .white
    /// Which piece is rendered in the preview window. Default king —
    /// most ornate silhouette, best canvas for material judgement.
    @State private var previewKind: PieceKind = .king

    var body: some View {
        @Bindable var customization = appModel.pieceCustomization

        // Single-column ScrollView — visionOS sheets size to content
        // intrinsic width, and a two-column HStack made the sheet
        // squeeze both columns. One vertical scroll keeps the layout
        // predictable at any sheet width.
        NavigationStack {
            ScrollView {
                VStack(spacing: Chess.Space.m) {
                    previewHeader(customization: customization)

                    ChessCard(.standard) {
                        VStack(alignment: .leading, spacing: Chess.Space.s) {
                            ChessSectionHeader("Material")
                            presetSection(customization: customization)
                            if customization.current.preset == .wood {
                                Divider().padding(.top, Chess.Space.xs)
                                pieceWoodSection(customization: customization)
                            }
                        }
                    }

                    ChessCard(.standard) {
                        VStack(alignment: .leading, spacing: Chess.Space.s) {
                            ChessSectionHeader("Tint")
                            colorSection(customization: customization)
                        }
                    }

                    ChessCard(.standard) {
                        VStack(alignment: .leading, spacing: Chess.Space.s) {
                            ChessSectionHeader("Board")
                            boardSection(customization: customization)
                        }
                    }

                    Button {
                        customization.resetToDefault()
                    } label: {
                        Label("Reset to default",
                              systemImage: "arrow.counterclockwise")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, Chess.Space.s)
                }
                .padding(Chess.Space.l)
                .frame(maxWidth: 1080)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pieces & Board")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismissWindow(id: LiveChessApp.piecesWindowID)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Top-of-sheet preview block — uses PiecePreviewView directly
    /// (which already brings its own 320 pt frame + .thinMaterial
    /// backdrop), with .clipped() so the 3-D king can't escape the
    /// card's bounds, then the inline side / piece-kind controls
    /// on a single row beneath. No outer ZStack and no second frame
    /// — the previous wrapping was fighting PiecePreviewView's own
    /// sizing and letting the piece overflow up past the sheet's
    /// title bar.
    @ViewBuilder
    private func previewHeader(customization: PieceCustomization) -> some View {
        VStack(spacing: Chess.Space.s) {
            PiecePreviewView(
                material: customization.current,
                previewSide: $previewSide,
                previewKind: $previewKind
            )
            .clipped()
            .clipShape(
                RoundedRectangle(cornerRadius: Chess.Radius.card,
                                 style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.card,
                                 style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )

            HStack(spacing: Chess.Space.m) {
                Picker("", selection: $previewSide) {
                    Text("White").tag(Side.white)
                    Text("Black").tag(Side.black)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                Menu {
                    ForEach(PieceKind.allCases, id: \.self) { kind in
                        Button(displayName(for: kind)) { previewKind = kind }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(displayName(for: previewKind))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .frame(minWidth: 100)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer()
            }
        }
    }

    // MARK: - Preview controls (which side / which piece to preview)

    private var previewControls: some View {
        HStack(spacing: 16) {
            // Side toggle (white / black)
            HStack(spacing: 6) {
                Text("Side")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Side", selection: $previewSide) {
                    Text("White").tag(Side.white)
                    Text("Black").tag(Side.black)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            Spacer(minLength: 16)

            // Piece kind toggle
            HStack(spacing: 6) {
                Text("Piece")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(PieceKind.allCases, id: \.self) { kind in
                        Button(displayName(for: kind)) { previewKind = kind }
                    }
                } label: {
                    HStack {
                        Text(displayName(for: previewKind))
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Preset chips

    @ViewBuilder
    private func presetSection(customization: PieceCustomization) -> some View {
        // Vertical settings-list (like Apple Settings rows) instead
        // of a cramped 3-col grid. Each row owns a full line so the
        // text never wraps and the visual swatch on the left gives
        // an at-a-glance preview of the material.
        VStack(spacing: 6) {
            ForEach(PieceMaterial.Preset.allCases) { preset in
                presetRow(preset, customization: customization)
            }
        }
    }

    @ViewBuilder
    private func presetRow(
        _ preset: PieceMaterial.Preset,
        customization: PieceCustomization
    ) -> some View {
        let isSelected = customization.current.preset == preset
        Button {
            customization.selectPreset(preset)
        } label: {
            HStack(spacing: Chess.Space.s) {
                MaterialSwatch(preset: preset)
                    .frame(width: 28, height: 28)
                Text(preset.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, Chess.Space.s)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row,
                                 style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.white.opacity(0.10))
                          : AnyShapeStyle(Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row,
                                 style: .continuous)
                    .strokeBorder(isSelected
                                  ? Color.white.opacity(0.25)
                                  : Color.white.opacity(0.06),
                                  lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }
}

// MARK: - Material swatch

/// Tiny visual preview of a `PieceMaterial.Preset`, shown to the left
/// of each row in the material list. Uses solid / gradient fills that
/// approximate what the material will look like on the 3-D piece, so
/// the row is scannable at a glance instead of label-only.
private struct MaterialSwatch: View {
    let preset: PieceMaterial.Preset

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.25),
                                      lineWidth: 0.5)
            )
            .overlay(
                // Subtle highlight crescent — sells the "sphere"
                // illusion so each chip reads as a polished material
                // sample rather than a flat colour blob.
                Circle()
                    .trim(from: 0.55, to: 0.85)
                    .stroke(.white.opacity(0.45), lineWidth: 1.2)
                    .padding(2)
            )
    }

    private var fill: AnyShapeStyle {
        switch preset {
        case .plasticMatte:
            return AnyShapeStyle(Color(red: 0.92, green: 0.92, blue: 0.92))
        case .plasticGlossy:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.white, Color(white: 0.78)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .lacquered:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.78, green: 0.16, blue: 0.18),
                         Color(red: 0.45, green: 0.05, blue: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .polishedMetal:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.95), Color(white: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .brushedMetal:
            return AnyShapeStyle(Color(white: 0.70))
        case .ceramic:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.97, green: 0.96, blue: 0.93),
                         Color(red: 0.85, green: 0.83, blue: 0.78)],
                startPoint: .top, endPoint: .bottom
            ))
        case .pearl:
            return AnyShapeStyle(AngularGradient(
                colors: [.pink.opacity(0.6), .cyan.opacity(0.4),
                         .white, .yellow.opacity(0.5), .pink.opacity(0.6)],
                center: .center
            ))
        case .glass:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.cyan.opacity(0.35),
                         Color.blue.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .wood:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.55, green: 0.36, blue: 0.18),
                         Color(red: 0.32, green: 0.18, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .marble:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.96), Color(white: 0.78)],
                startPoint: .top, endPoint: .bottom
            ))
        }
    }
}

// Wrapper to put `MaterialSwatch` next to the type above. The struct
// `PieceCustomizationView` continues below — Swift allows reopening
// via this extension.
extension PieceCustomizationView {
    /// Empty hook — kept so the closing `}` of the main struct above
    /// doesn't change the surrounding section signatures.
    @ViewBuilder
    private func _materialSectionMarker() -> some View {
        EmptyView()
    }

    // MARK: - Color pickers

    @ViewBuilder
    private func colorSection(customization: PieceCustomization) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour")
                .font(.headline)
            // Hint: for texture-backed presets the colour multiplies
            // with the texture, so a near-white tint keeps the
            // photographed wood / marble natural; bold tints recolour
            // the whole material.
            if customization.current.preset == .wood || customization.current.preset == .marble {
                Text("Tint multiplies the texture — pick a near-white tint to keep the natural look, or a bold tint to repaint the material entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                colorPicker(
                    title: "White",
                    binding: bindingFor(\.whiteColor, in: customization)
                )
                colorPicker(
                    title: "Black",
                    binding: bindingFor(\.blackColor, in: customization)
                )
            }
        }
    }

    // MARK: - Board (frame + light/dark squares)

    @ViewBuilder
    private func boardSection(customization: PieceCustomization) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Re-skin the playing surface — pick a material and colours that pair well with your pieces. Changes apply live to any open game.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // LIVE BOARD PREVIEW — 2-D swatch that mirrors the
            // current customization. Sits at the top of the section
            // so every chip / colour-picker change underneath
            // produces a visible result the user can see before
            // committing.
            HStack {
                Spacer()
                BoardPreviewView(material: customization.current)
                    .frame(width: 260, height: 260)
                Spacer()
            }

            // Squares — material chips + light/dark colour pickers.
            VStack(alignment: .leading, spacing: 8) {
                Text("Squares")
                    .font(.subheadline.weight(.semibold))
                boardMaterialChips(
                    selected: customization.current.squareMaterial,
                    onPick: { customization.current.squareMaterial = $0 }
                )
                if customization.current.squareMaterial == .wood {
                    woodPair(
                        leftLabel: "Light wood",
                        leftSelected: customization.current.lightSquareWood,
                        leftPick: { customization.current.lightSquareWood = $0 },
                        rightLabel: "Dark wood",
                        rightSelected: customization.current.darkSquareWood,
                        rightPick: { customization.current.darkSquareWood = $0 }
                    )
                }
                HStack(alignment: .top, spacing: 16) {
                    colorPicker(
                        title: "Light",
                        binding: bindingFor(\.lightSquareColor, in: customization)
                    )
                    colorPicker(
                        title: "Dark",
                        binding: bindingFor(\.darkSquareColor, in: customization)
                    )
                }
            }

            // Frame — material chips + single colour picker.
            VStack(alignment: .leading, spacing: 8) {
                Text("Frame")
                    .font(.subheadline.weight(.semibold))
                boardMaterialChips(
                    selected: customization.current.frameMaterial,
                    onPick: { customization.current.frameMaterial = $0 }
                )
                if customization.current.frameMaterial == .wood {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frame wood")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        woodTypeChips(
                            selected: customization.current.frameWood,
                            onPick: { customization.current.frameWood = $0 }
                        )
                    }
                }
                colorPicker(
                    title: "Frame colour",
                    binding: bindingFor(\.frameColor, in: customization)
                )
                .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    /// Wood-type pickers that show up under the Pieces section when
    /// the user picks the Wood preset — so a "wood pieces" set can
    /// have e.g. rosewood whites and ebony blacks instead of the
    /// hardcoded oak/ebony defaults.
    @ViewBuilder
    private func pieceWoodSection(customization: PieceCustomization) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wood species")
                .font(.subheadline.weight(.semibold))
            woodPair(
                leftLabel: "White pieces",
                leftSelected: customization.current.whitePieceWood,
                leftPick: { customization.current.whitePieceWood = $0 },
                rightLabel: "Black pieces",
                rightSelected: customization.current.blackPieceWood,
                rightPick: { customization.current.blackPieceWood = $0 }
            )
        }
    }

    /// Two side-by-side labelled wood-type chip rows, used by both
    /// the Pieces wood section (white / black side) and the Squares
    /// wood section (light / dark squares).
    @ViewBuilder
    private func woodPair(
        leftLabel: String,
        leftSelected: WoodType,
        leftPick: @escaping (WoodType) -> Void,
        rightLabel: String,
        rightSelected: WoodType,
        rightPick: @escaping (WoodType) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(leftLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                woodTypeChips(selected: leftSelected, onPick: leftPick)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rightLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                woodTypeChips(selected: rightSelected, onPick: rightPick)
            }
        }
    }

    /// Compact chip selector for `WoodType`. Same visual language as
    /// `boardMaterialChips` — outlined pill, accent fill when picked.
    @ViewBuilder
    private func woodTypeChips(
        selected: WoodType,
        onPick: @escaping (WoodType) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(WoodType.allCases) { wood in
                let isSelected = wood == selected
                Button {
                    onPick(wood)
                } label: {
                    Text(wood.displayName)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                      ? AnyShapeStyle(Color.white.opacity(0.10))
                                      : AnyShapeStyle(Color.gray.opacity(0.10)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.20),
                                        lineWidth: isSelected ? 1.0 : 0.5)
                        }
                }
                .buttonStyle(.plain)
                .hoverEffect()
            }
        }
    }

    /// Compact 4-chip row for the board material selector. Smaller
    /// surface than the piece preset grid (only matte / polished /
    /// wood / marble make sense here — pearl, glass, lacquered etc.
    /// don't fit a board).
    @ViewBuilder
    private func boardMaterialChips(
        selected: BoardMaterial,
        onPick: @escaping (BoardMaterial) -> Void
    ) -> some View {
        // Each chip is a fixed-width pill so its label always sits on
        // one line — the earlier flexible HStack squeezed the labels
        // until they wrapped character-by-character ('P o l i s h e d'
        // in the user's screenshot).
        HStack(spacing: 8) {
            ForEach(BoardMaterial.allCases) { material in
                let isSelected = material == selected
                Button {
                    onPick(material)
                } label: {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(material.displayName)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected
                                  ? AnyShapeStyle(Color.white.opacity(0.10))
                                  : AnyShapeStyle(Color.gray.opacity(0.12)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.25),
                                    lineWidth: isSelected ? 1.0 : 0.5)
                    }
                }
                .buttonStyle(.plain)
                .hoverEffect()
            }
        }
    }

    private func bindingFor(
        _ keyPath: WritableKeyPath<PieceMaterial, PieceColor>,
        in customization: PieceCustomization
    ) -> Binding<Color> {
        Binding(
            get: { customization.current[keyPath: keyPath].swiftUI },
            set: { newColor in
                customization.current[keyPath: keyPath] = PieceColor(newColor)
            }
        )
    }

    private func colorPicker(title: String, binding: Binding<Color>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            // Visual swatch under the picker so the user sees what
            // they have selected at a glance — visionOS's ColorPicker
            // surface hides the chosen colour behind a system menu.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(binding.wrappedValue)
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.secondary.opacity(0.4), lineWidth: 0.5)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayName(for kind: PieceKind) -> String {
        switch kind {
        case .pawn:   return "Pawn"
        case .knight: return "Knight"
        case .bishop: return "Bishop"
        case .rook:   return "Rook"
        case .queen:  return "Queen"
        case .king:   return "King"
        }
    }
}
