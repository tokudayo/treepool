// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .executable(name: "twt", targets: ["twt"]),
]

var targets: [Target] = [
    .target(name: "TreepoolCore"),
    .executableTarget(
        name: "twt",
        dependencies: [
            "TreepoolCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        plugins: [.plugin(name: "VersionPlugin")]
    ),
    .testTarget(
        name: "TreepoolCoreTests",
        dependencies: [
            "TreepoolCore",
            .product(name: "Testing", package: "swift-testing"),
        ]
    ),
    .executableTarget(
        name: "VersionGenerator",
        path: "Plugins/VersionGenerator"
    ),
    .plugin(
        name: "VersionPlugin",
        capability: .buildTool(),
        dependencies: ["VersionGenerator"]
    ),
]

#if os(macOS)
products.append(.executable(name: "TreepoolMenu", targets: ["TreepoolMenu"]))
targets.append(
    .executableTarget(
        name: "TreepoolMenu",
        dependencies: ["TreepoolCore"],
        resources: [.process("Resources")]
    )
)
#endif

let package = Package(
    name: "Treepool",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: targets
)
