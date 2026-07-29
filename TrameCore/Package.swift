// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TrameCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrameProtocol", targets: ["TrameProtocol"]),
        .library(name: "TrameDaemon", targets: ["TrameDaemon"]),
        .library(name: "TrameClient", targets: ["TrameClient"]),
        .library(name: "TrameGit", targets: ["TrameGit"]),
        .library(name: "TrameMCP", targets: ["TrameMCP"]),
        .executable(name: "trame-core", targets: ["trame-core"]),
        .executable(name: "trame-smoke", targets: ["trame-smoke"]),
    ],
    targets: [
        .target(name: "CPTY"),
        .target(name: "TrameProtocol"),
        .target(name: "TrameDaemon", dependencies: ["CPTY", "TrameProtocol"]),
        .target(name: "TrameClient", dependencies: ["TrameProtocol"]),
        .target(name: "TrameGit"),
        .testTarget(name: "TrameGitTests", dependencies: ["TrameGit"]),
        .target(name: "TrameMCP"),
        .testTarget(name: "TrameMCPTests", dependencies: ["TrameMCP"]),
        .executableTarget(name: "trame-core", dependencies: ["TrameDaemon"]),
        .executableTarget(name: "trame-smoke", dependencies: ["TrameClient", "TrameProtocol"]),
    ]
)
