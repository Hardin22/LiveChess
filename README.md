# LiveChess

A native **visionOS** chess game built with SwiftUI + RealityKit. Play locally, vs Stockfish, or against Lichess players — at a real table in your room (AR passthrough) or seated inside one of three fully-immersive 3D environments.

## Features

- **Local two-player** and **vs Stockfish** modes, with full standard chess rules (castling, en passant, promotion, threefold repetition, fifty-move rule).
- **Lichess integration**: online matches, puzzle pulls from the Lichess puzzle DB, and a daily-puzzle slot with per-day locking.
- **Four scene environments**:
  - `ar` — Vision Pro passthrough with ARKit plane detection; board lands on a real table.
  - `dwarvenHall` — moody noir interior with sconce flicker and dust motes.
  - `auditoriumStage` — conference-style stage with banked audience seats.
  - `balcony` — cliffside balcony at golden hour, with a glass-railing view of the mountains.
- **Cinematic per-env lighting** — each env owns its own key/rim/fill rig in code (RealityKit `SpotLightComponent` / `PointLightComponent` / `DirectionalLightComponent`), tuned to the asset.
- **Tournament-feel chess board** — 60 mm squares, inlaid coordinate labels (a–h / 1–8) engraved into the frame, hover/lift feedback on pieces.

## Tech stack

- **SwiftUI** for menu + HUD; **RealityKit** for all 3D rendering.
- **Swift Concurrency** end-to-end (`@MainActor` scene loaders, async/await for env mounting and Stockfish IO).
- **Stockfish** via the bundled [chesskit-engine](Packages/chesskit-engine) Swift package.
- **Reality Composer Pro** asset package at [Packages/RealityKitContent](Packages/RealityKitContent).
- Pipeline: **Blender → USDZ** (`UsdPreviewSurface`, instancing on, Y-up / -Z-forward) → bundled in `LiveChess/Resources/*.usdz`.

## Build & run

Requires **Xcode 16+** and **visionOS 26 SDK**.

```bash
open LiveChess.xcodeproj
```

Build for `Apple Vision Pro` (simulator or device) and run. The app launches into the main menu; pick **vs Stockfish** or **Local match**, then choose an environment from the picker.

For a quick CLI build:

```bash
xcodebuild -project LiveChess.xcodeproj \
  -scheme LiveChess \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug \
  build
```

## Project layout

```
LiveChess/
├── AI/                    — Stockfish driver, search depth presets
├── Domain/                — Pure chess types (Square, Piece, Position, Move generation)
├── Lichess/               — Lichess REST + puzzle bundling
├── Main Menu/             — SwiftUI menu, settings, theme, navigation
├── Match/                 — Local/online game state machines
├── Puzzles/               — Puzzle player, rating, daily slot
├── Resources/             — USDZ environments, Stockfish NNUE, opening book
├── Rules/                 — Move legality, check detection, endgame conditions
├── Scene/                 — 3D scene wiring
│   ├── BoardSurface.swift          — 8×8 board geometry + materials
│   ├── ChessRenderer.swift         — Piece entities, animation
│   ├── ChessSceneView.swift        — Top-level RealityView host
│   ├── Environments/
│   │   ├── SceneEnvironment.swift           — env enum + EnvironmentMount contract
│   │   ├── EnvironmentLighting.swift        — shared light helpers, table anchor
│   │   ├── DwarvenHallEnvironment.swift     — dwarven hall loader + noir rig
│   │   ├── AuditoriumStageEnvironment.swift — stage loader + arena lighting
│   │   └── BalconyEnvironment.swift         — balcony loader + golden-hour rig
│   ├── Placement/                  — AR plane detection + drag-to-reposition
│   └── SceneMetrics.swift          — board / piece / table dimensions
└── Theme/                 — Colors, fonts, design tokens
```

## Adding a new environment

1. Author the room in Blender. Keep one top-level `Xform` named for the table the board should sit on (so the loader can anchor the player seated in front of it).
2. Export to USDZ with `UsdPreviewSurface` materials, instancing on, Y-up / -Z-forward. Cap textures at 2K for sensible bundle size.
3. Drop the `.usdz` into `LiveChess/Resources/`.
4. Add a new case to `SceneEnvironment` and a sibling loader file in `Scene/Environments/` conforming to `EnvironmentScene` (return an `EnvironmentMount` with the board position).
5. Wire the new case into `EnvironmentLoader.mount`.

`BalconyEnvironment.swift` is a recent, well-commented example covering the common quirks (chair+table fused into one mesh, asymmetric bounds center, an env rotation needed to land chair-to-chair across the table).

## License

Private project — all rights reserved unless explicitly stated otherwise. Stockfish is GPL-3.0 (preserved in the [chesskit-engine](Packages/chesskit-engine) package).
