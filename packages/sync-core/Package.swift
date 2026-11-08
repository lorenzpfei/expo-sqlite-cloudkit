// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "SyncCore",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "SyncCore", targets: ["SyncCore"]),
    .library(name: "SyncCloudKit", targets: ["SyncCloudKit"]),
  ],
  targets: [
    .target(name: "SyncCore"),
    .target(name: "SyncCloudKit", dependencies: ["SyncCore"]),
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(
      name: "SystemSQLite",
      dependencies: ["SyncCore", .target(name: "CSQLite", condition: .when(platforms: [.linux]))]
    ),
    .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore", "SystemSQLite"], resources: [.copy("Fixtures")]),
    .testTarget(name: "SyncCloudKitTests", dependencies: ["SyncCloudKit", "SyncCore"]),
  ]
)
