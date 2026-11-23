// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ir2Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Ir2Kit", targets: ["Ir2Kit"])],
    targets: [
        .target(name: "Ir2Kit"),
        .testTarget(name: "Ir2KitTests", dependencies: ["Ir2Kit"]),
    ]
)
