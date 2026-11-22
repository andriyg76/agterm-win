// swift-tools-version: 6.0
import Foundation
import PackageDescription

// scripts/fetch-webview2.ps1 unpacks the WebView2 SDK NuGet package here; it is not committed
let webView2 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/vendor/webview2/build/native"
// scripts/make-icon.sh writes the icon resource from agterm's app icon; it is committed
let iconResource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/Resources/agterm.res"

let package = Package(
    name: "agterm-win",
    dependencies: [
        .package(path: "../agtermCore"),
    ],
    targets: [
        .target(
            name: "WebView2Shim",
            cxxSettings: [.unsafeFlags(["-I", webView2 + "/include"])],
            linkerSettings: [
                .unsafeFlags(["-L", webView2 + "/x64"]),
                // static, so no Microsoft DLL ships beside the exe
                .linkedLibrary("WebView2LoaderStatic"),
                .linkedLibrary("version"),
                .linkedLibrary("advapi32"),
                .linkedLibrary("shell32"),
                .linkedLibrary("ole32"),
                .linkedLibrary("bcrypt"),
                .linkedLibrary("user32"),
            ]
        ),
        .target(
            name: "NativeShim",
            linkerSettings: [.linkedLibrary("d2d1"), .linkedLibrary("dwrite"), .linkedLibrary("user32")]
        ),
        .executableTarget(
            name: "agterm-win",
            dependencies: ["WebView2Shim", "NativeShim", .product(name: "agtermCore", package: "agtermCore")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("user32"),
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup", "-Xlinker", iconResource]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
