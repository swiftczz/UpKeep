// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "AppMint",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "AppMint", targets: ["AppMint"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5")
  ],
  targets: [
    .executableTarget(
      name: "AppMint",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "AppMint",
      linkerSettings: [
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "AppMintTests",
      dependencies: ["AppMint"],
      path: "AppMintTests"
    ),
  ]
)
