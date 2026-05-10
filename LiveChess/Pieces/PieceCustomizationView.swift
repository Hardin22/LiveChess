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

    @Environment(\.dismiss) private var dismiss
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

        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PiecePreviewView(
                        material: customization.current,
                        previewSide: $previewSide,
                        previewKind: $previewKind
                    )

                    previewControls

                    Divider()

                    presetSection(customization: customization)

                    Divider()

                    colorSection(customization: customization)

                    if customization.current.preset == .wood {
                        pieceWoodSection(customization: customization)
                    }

                    Divider()

                    boardSection(customization: customization)

                    Divider()

                    Button("Reset to default") {
                        customization.resetToDefault()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding(24)
                .frame(maxWidth: 540)
            }
            .navigationTitle("Pieces")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Material")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                spacing: 8
            ) {
                ForEach(PieceMaterial.Preset.allCases) { preset in
                    presetChip(preset, customization: customization)
                }
            }
        }
    }

    @ViewBuilder
    private func presetChip(
        _ preset: PieceMaterial.Preset,
        customization: PieceCustomization
    ) -> some View {
        let isSelected = customization.current.preset == preset
        Button {
            customization.selectPreset(preset)
        } label: {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
                Text(preset.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                          : AnyShapeStyle(Color.gray.opacity(0.12)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isSelected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .hoverEffect()
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
            Text("Board")
                .font(.headline)
            Text("Re-skin the playing surface — pick a material and colours that pair well with your pieces. Changes apply live to any open game.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                      ? AnyShapeStyle(Color.accentColor.opacity(0.20))
                                      : AnyShapeStyle(Color.gray.opacity(0.10)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.20),
                                        lineWidth: isSelected ? 1.2 : 0.5)
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
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected
                                  ? AnyShapeStyle(Color.accentColor.opacity(0.20))
                                  : AnyShapeStyle(Color.gray.opacity(0.12)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                    lineWidth: isSelected ? 1.5 : 0.5)
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
