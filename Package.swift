// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentStatusLight",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentStatusLight", targets: ["AgentStatusLight"])
    ],
    targets: [
        .executableTarget(name: "AgentStatusLight")
    ]
)
