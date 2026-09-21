// swift-tools-version: 6.0
import PackageDescription

// Semif's scorer tests need MLX, which cannot link from standalone `swiftc`,
// so the scorer and its pure prompt contract live in this package (issue #12).
// The same sources are compiled into the ShortReel app via `apple/project.yml`
// (path `SemanticIf/Sources/SemanticIf`); there is exactly one copy of each file.
let package = Package(
    name: "SemanticIf",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SemanticIf", targets: ["SemanticIf"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
    ],
    targets: [
        .target(
            name: "SemanticIf",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "SemanticIfTests",
            dependencies: [
                "SemanticIf",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
    ]
)
