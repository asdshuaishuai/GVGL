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
        .executable(name: "gvgl", targets: ["gvgl"]),
        .executable(name: "gvglui", targets: ["gvglui"]),
    ],
    targets: [
        .target(name: "GVGLCore"),
        .target(name: "GVGLSync", dependencies: ["GVGLCore"]),
        .target(name: "GVGLServer", dependencies: ["GVGLCore", "GVGLSync"]),
        .target(name: "GVGLQuery", dependencies: ["GVGLCore"]),
        .executableTarget(name: "gvgl", dependencies: ["GVGLCore", "GVGLSync", "GVGLServer"]),
        .executableTarget(name: "gvglui", dependencies: ["GVGLCore", "GVGLQuery"]),
        .testTarget(name: "GVGLCoreTests", dependencies: ["GVGLCore"]),
        .testTarget(name: "GVGLSyncTests", dependencies: ["GVGLSync", "GVGLServer"]),
        .testTarget(name: "GVGLQueryTests", dependencies: ["GVGLQuery", "GVGLServer", "GVGLSync"]),
    ],
    swiftLanguageModes: [.v5]
)
