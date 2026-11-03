// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RouteSync",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that doesn't need Bluetooth or a window, so it can be tested.
        .target(name: "RouteCore"),
        // Bluetooth/ isn't built: the watch won't accept the Mac while it's paired to
        // a phone. It's kept for an iPhone app, which could use the phone's pairing.
        .executableTarget(name: "RouteSync", dependencies: ["RouteCore"]),
        .testTarget(name: "RouteCoreTests", dependencies: ["RouteCore"]),
    ]
)
