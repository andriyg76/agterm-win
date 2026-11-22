// swift-tools-version: 6.0
import Foundation
import PackageDescription

// scripts/fetch-webview2.ps1 unpacks the WebView2 SDK NuGet package here; it is not committed
let webView2 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/vendor/webview2/build/native"

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
                .linkedLibrary("WebView2Loader.dll"),
                .linkedLibrary("ole32"),
                .linkedLibrary("user32"),
            ]
        ),
        .executableTarget(
            name: "agterm-win",
            dependencies: ["WebView2Shim", .product(name: "agtermCore", package: "agtermCore")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("user32"),
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
