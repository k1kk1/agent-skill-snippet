// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentRecipes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentRecipesCore", targets: ["AgentRecipesCore"]),
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
        .executable(name: "agentrecipes", targets: ["agentrecipes"]),
        .executable(name: "AgentRecipesApp", targets: ["AgentRecipesApp"]),
    ],
    targets: [
        .target(name: "AgentRecipesCore"),
        .target(name: "HerdrKit", dependencies: ["AgentRecipesCore"]),
        .executableTarget(name: "agentrecipes", dependencies: ["AgentRecipesCore", "HerdrKit"]),
        .executableTarget(name: "AgentRecipesApp", dependencies: ["AgentRecipesCore", "HerdrKit"]),
        .testTarget(name: "AgentRecipesCoreTests", dependencies: ["AgentRecipesCore", "HerdrKit"]),
    ]
)
