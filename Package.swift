// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GVGL",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GVGLCore", targets: ["GVGLCore"]),
        .library(name: "GVGLSync", targets: ["GVGLSync"]),
        .library(name: "GVGLServer", targets: ["GVGLServer"]),
        .library(name: "GVGLQuery", targets: ["GVGLQuery"]),
        // Read + act: the computer-use execution layer. Lives outside the
        // daemon so the daemon keeps its auditable read-only guarantee.
        // Module name is `GVGLAction` (not `GVGLAct`) because macOS volumes are
        // case-insensitive by default: `GVGLAct` and the `gvglact` executable
        // directory would collapse into one source folder.
        .library(name: "GVGLAction", targets: ["GVGLAction"]),
        .executable(name: "gvgl", targets: ["gvgl"]),
        .executable(name: "gvglui", targets: ["gvglui"]),
        .executable(name: "gvglact", targets: ["gvglact"]),
    ],
    targets: [
        .target(name: "GVGLCore"),
        .target(name: "GVGLSync", dependencies: ["GVGLCore"]),
        .target(name: "GVGLServer", dependencies: ["GVGLCore", "GVGLSync"]),
        .target(name: "GVGLQuery", dependencies: ["GVGLCore"]),
        .target(name: "GVGLAction", dependencies: ["GVGLCore", "GVGLQuery"]),
        .executableTarget(name: "gvgl", dependencies: ["GVGLCore", "GVGLSync", "GVGLServer"]),
        .executableTarget(name: "gvglui", dependencies: ["GVGLCore", "GVGLQuery", "GVGLAction"]),
        .executableTarget(name: "gvglact", dependencies: ["GVGLAction", "GVGLCore", "GVGLQuery"]),
        .testTarget(name: "GVGLCoreTests", dependencies: ["GVGLCore"]),
        .testTarget(name: "GVGLSyncTests", dependencies: ["GVGLSync", "GVGLServer"]),
        .testTarget(name: "GVGLQueryTests", dependencies: ["GVGLQuery", "GVGLServer", "GVGLSync"]),
        .testTarget(name: "GVGLActionTests", dependencies: ["GVGLAction", "GVGLCore"]),
    ],
    swiftLanguageModes: [.v5]
)
