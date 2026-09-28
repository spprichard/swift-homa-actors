// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HomaActorPOC",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HomaActorSystem", targets: ["HomaActorSystem"]),
        .executable(name: "actor-demo", targets: ["ActorDemo"]),
    ],
    targets: [
        .target(name: "CHoma"),
        .target(name: "HomaActorSystem", dependencies: ["CHoma"]),
        .executableTarget(name: "ActorDemo", dependencies: ["HomaActorSystem"]),
        .testTarget(name: "HomaActorSystemTests", dependencies: ["HomaActorSystem"]),
    ]
)
