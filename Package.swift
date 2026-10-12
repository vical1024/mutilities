// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacInterfaceController",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacInterfaceController", targets: ["MacInterfaceController"]),
        .executable(name: "FunctionKeyRestore", targets: ["FunctionKeyRestore"]),
        .executable(name: "DisplayGuard", targets: ["DisplayGuard"])
    ],
    targets: [
        .target(name: "FunctionKeySupport"),
        .target(name: "DisplaySupport"),
        .executableTarget(name: "DisplayGuard", dependencies: ["DisplaySupport"]),
        .executableTarget(name: "FunctionKeyRestore", dependencies: ["FunctionKeySupport"]),
        .executableTarget(
            name: "MacInterfaceController",
            dependencies: ["FunctionKeySupport", "DisplaySupport"],
            path: "Sources/MacInterfaceController"
        ),
        .testTarget(
            name: "MacInterfaceControllerTests",
            dependencies: ["MacInterfaceController", "DisplaySupport"]
        )
    ],
    swiftLanguageModes: [.v5]
)
