// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "AppPulse",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "AppPulse", targets: ["AppPulse"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5")
  ],
  targets: [
    .executableTarget(
      name: "AppPulse",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "AppPulse",
      linkerSettings: [
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "AppPulseTests",
      dependencies: ["AppPulse"],
      path: "AppPulseTests"
    ),
  ]
)
