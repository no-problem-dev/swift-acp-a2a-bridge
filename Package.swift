// swift-tools-version: 6.2
import PackageDescription

// swift-acp-a2a-bridge — exposes a swift-a2a agent as an ACP agent.
//
// Layering: this is the connection layer that sits *on top of* both foundations
// (it depends on swift-acp and swift-a2a; neither depends on it). The bridge
// turns the ACP host↔agent vertical contract into an A2A message exchange, and
// maps the A2A task event stream back onto ACP `session/update` notifications.
let package = Package(
    name: "swift-acp-a2a-bridge",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "ACPA2ABridge", targets: ["ACPA2ABridge"]),
    ],
    dependencies: [
        .package(path: "../swift-acp"),
        .package(path: "../swift-a2a"),
    ],
    targets: [
        .target(
            name: "ACPA2ABridge",
            dependencies: [
                .product(name: "ACPCore", package: "swift-acp"),
                .product(name: "ACPAgent", package: "swift-acp"),
                .product(name: "ACPClient", package: "swift-acp"),
                .product(name: "A2ACore", package: "swift-a2a"),
                .product(name: "A2AServer", package: "swift-a2a"),
            ]
        ),
        .testTarget(
            name: "ACPA2ABridgeTests",
            dependencies: [
                "ACPA2ABridge",
                .product(name: "ACPCore", package: "swift-acp"),
                .product(name: "ACPTransport", package: "swift-acp"),
                .product(name: "A2ACore", package: "swift-a2a"),
                .product(name: "A2AServer", package: "swift-a2a"),
            ]
        ),
    ]
)
