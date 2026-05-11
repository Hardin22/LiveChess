// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessKitEngine",
    platforms: [
        .iOS(.v16),
        .watchOS(.v9),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "ChessKitEngine", targets: ["ChessKitEngine"])
    ],
    targets: [
        .target(
            name: "ChessKitEngine",
            dependencies: ["ChessKitEngineCore"]
        ),
        .target(
            name: "ChessKitEngineCore",
            cxxSettings: [
                .define("NNUE_EMBEDDING_OFF"),
                .define("NO_PEXT")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "ChessKitEngineTests",
            dependencies: ["ChessKitEngine"],
            exclude: ["EngineTests/Lc0Tests.swift"],
            resources: [.copy("EngineTests/Resources/192x15_network")]
        )
    ],
    cxxLanguageStandard: .gnucxx17
)

// MARK: - ChessKitEngineCore excludes
// lc0 is intentionally disabled: its vendored Eigen 3.4.0 copy is missing
// `Eigen/Core` (excluded by Eigen's own .gitignore matching `core`
// case-insensitively when vendored on macOS). The app uses Stockfish only.
if let coreTarget = package.targets.first(where: { $0.name == "ChessKitEngineCore" }) {
    coreTarget.exclude = [
        "Engines/lc0",
        "Engines/Extensions/lc0+engine.cpp",
        "Engines/Extensions/lc0+engine.h"
    ]
}
