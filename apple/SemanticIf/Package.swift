// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SemanticIf",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SemanticIf", targets: ["SemanticIf"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .target(name: "SemanticIf", dependencies: [
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers"),
        ], linkerSettings: [.linkedFramework("CoreML")]),
        .testTarget(name: "SemanticIfTests", dependencies: ["SemanticIf"],
                    resources: [.copy("Fixtures")]),
    ]
)
