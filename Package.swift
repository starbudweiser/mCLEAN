// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mCLEAN",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique sans AppKit : lecture de la mémoire, calculs, règles, nettoyage. Testable.
        .target(name: "MCleanCore"),
        // Application barre de menus.
        .executableTarget(name: "mCLEAN", dependencies: ["MCleanCore"]),
        .testTarget(name: "MCleanCoreTests", dependencies: ["MCleanCore"]),
    ]
)
