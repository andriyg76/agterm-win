// swift-tools-version: 6.2
import Foundation
import PackageDescription

// scripts/make-icon.sh writes the icon resource from agterm's app icon; it is committed
let iconResource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/Resources/agterm.res"

let package = Package(
    name: "agterm-win",
    dependencies: [
        .package(path: "../agtermCore"),
    ],
    targets: [
        // scripts/fetch-ghostty-vt.ps1 lays out the pinned libghostty-vt release here
        .binaryTarget(name: "GhosttyVT", path: "vendor/ghostty-vt.artifactbundle"),
        .target(
            name: "NativeShim",
            dependencies: ["GhosttyVT"],
            cxxSettings: [.define("GHOSTTY_STATIC")],
            linkerSettings: [.linkedLibrary("d2d1"), .linkedLibrary("dwrite"), .linkedLibrary("dwmapi"), .linkedLibrary("user32"),
                             .linkedLibrary("comctl32"), .linkedLibrary("uxtheme"), .linkedLibrary("gdi32"), .linkedLibrary("bcrypt"),
                             .linkedLibrary("ntdll"), .linkedLibrary("runtimeobject"), .linkedLibrary("advapi32"), .linkedLibrary("shell32")]
        ),
        // the Win32-free logic the native window runs, so `swift test` covers it on any host
        .target(name: "AgtermWinKit", dependencies: [.product(name: "agtermCore", package: "agtermCore")]),
        .testTarget(name: "AgtermWinKitTests", dependencies: ["AgtermWinKit"], path: "tests/AgtermWinKitTests"),
        .executableTarget(
            name: "agterm-win",
            dependencies: ["NativeShim", "AgtermWinKit", .product(name: "agtermCore", package: "agtermCore")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("user32"),
                .linkedLibrary("shell32"),
                .linkedLibrary("advapi32"),
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup", "-Xlinker", iconResource]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
