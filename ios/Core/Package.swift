// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IntercomCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "IntercomCore", targets: ["IntercomCore"])],
    dependencies: [
        // CryptoKit is Apple-only; swift-crypto keeps the core testable on Linux too.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "IntercomCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "IntercomCoreTests", dependencies: ["IntercomCore"]),
    ]
)
