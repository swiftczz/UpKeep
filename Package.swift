// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Upkeep",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "Upkeep", targets: ["Upkeep"]),
    .executable(name: "UpkeepPrivilegedHelper", targets: ["UpkeepPrivilegedHelper"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "UpkeepPrivilegedHelperProtocol",
      dependencies: [],
      path: "UpkeepPrivilegedHelperProtocol"
    ),
    .executableTarget(
      name: "Upkeep",
      dependencies: ["UpkeepPrivilegedHelperProtocol"],
      path: "Upkeep",
      linkerSettings: [
        .linkedFramework("CoreServices"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement")
      ]
    ),
    .executableTarget(
      name: "UpkeepPrivilegedHelper",
      dependencies: ["UpkeepPrivilegedHelperProtocol"],
      path: "UpkeepPrivilegedHelper",
      linkerSettings: [
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
