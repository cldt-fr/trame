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
        .executableTarget(name: "trame-core", dependencies: ["TrameDaemon"]),
        .executableTarget(name: "trame-smoke", dependencies: ["TrameClient", "TrameProtocol"]),
    ]
)
