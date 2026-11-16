// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let package = Package(
    name: "AgentKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentKitExample", targets: ["AgentKitExample"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "AgentUI", targets: ["AgentUI"]),
    ],
    dependencies: [.package(url: "https://github.com/hugocxl/iconscxl.git", from: "0.1.6")],
    targets: [
        .executableTarget(name: "AgentKitExample", dependencies: ["AgentCore", "AgentRuntime", "AgentUI"], path: "Examples/ConversationApp", swiftSettings: swift5),
        .target(name: "AgentCore", resources: [.copy("Resources/Themes")], swiftSettings: swift5),
        .target(name: "AgentRuntime", dependencies: ["AgentCore"], swiftSettings: swift5),
        .target(name: "AgentUI", dependencies: ["AgentCore", .product(name: "IconsCXL", package: "iconscxl")], resources: [.copy("Resources/TabIcons")], swiftSettings: swift5),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"], swiftSettings: swift5),
        .testTarget(name: "AgentRuntimeTests", dependencies: ["AgentRuntime", "AgentCore"], swiftSettings: swift5),
        .testTarget(name: "AgentUITests", dependencies: ["AgentUI", "AgentCore", "AgentRuntime"], swiftSettings: swift5),
    ]
)
