// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Upkeep",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "Upkeep", targets: ["Upkeep"])
  ],
  dependencies: [],
  targets: [
    .executableTarget(
      name: "Upkeep",
      dependencies: [],
      path: "Upkeep",
      linkerSettings: [
        .linkedFramework("CoreServices"),
        .linkedFramework("Security")
      ]
    ),
    .testTarget(
      name: "UpkeepTests",
      dependencies: ["Upkeep"],
      path: "UpkeepTests"
    ),
  ]
)
