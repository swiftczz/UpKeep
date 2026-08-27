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
  dependencies: [],
  targets: [
    .executableTarget(
      name: "AppMint",
      dependencies: [],
      path: "AppMint",
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "AppMintTests",
      dependencies: ["AppMint"],
      path: "AppMintTests"
    ),
  ]
)
