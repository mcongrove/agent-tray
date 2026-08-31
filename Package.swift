// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentTray",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentTray", targets: ["AgentTray"])
    ],
    targets: [
        .executableTarget(
            name: "AgentTray",
            path: "Sources/AgentTray",
            resources: [.copy("Resources/bot.png")]
        )
    ]
)
