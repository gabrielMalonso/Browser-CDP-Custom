// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Custom-CDP-Browser",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CustomCDPBrowser",
            dependencies: ["KeyboardShortcuts"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/ChromeIcon.png"),
                .copy("Resources/MenuBarIcon.svg"),
            ]
        ),
        .testTarget(
            name: "CustomCDPBrowserTests",
            dependencies: ["CustomCDPBrowser"]
        ),
    ]
)
