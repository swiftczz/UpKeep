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
  targets: [
    .executableTarget(
      name: "AppPulse",
      path: "AppPulse"
    ),
    .testTarget(
      name: "AppPulseTests",
      dependencies: ["AppPulse"],
      path: "AppPulseTests"
    ),
  ]
)
