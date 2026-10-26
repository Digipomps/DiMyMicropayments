// swift-tools-version: 5.9

import Foundation
import PackageDescription

private func hasPackageManifest(at candidate: String) -> Bool {
    let manifestPath = (candidate as NSString).appendingPathComponent("Package.swift")
    return FileManager.default.fileExists(atPath: manifestPath)
}

private func localPackagePath(from environmentKey: String) -> String? {
    let environment = ProcessInfo.processInfo.environment
    guard let candidate = environment[environmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !candidate.isEmpty else {
        return nil
    }

    guard hasPackageManifest(at: candidate) else {
        return nil
    }

    return candidate
}

let cellProtocolDependency: Package.Dependency = {
    // A SwiftPM source-control checkout lives beside its sibling checkouts. Do
    // not infer a local dependency from that layout: it gives CellProtocol two
    // source locations when a consumer also depends on CellProtocol directly.
    if let localPath = localPackagePath(from: "CELLPROTOCOL_LOCAL_PACKAGE_PATH") {
        return .package(path: localPath)
    }
    return .package(
        url: "https://github.com/Digipomps/CellProtocol.git",
        .upToNextMinor(from: "2026.9.3")
    )
}()

let package = Package(
    name: "DiMyMicropayments",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "DiMyPaymentTypes", targets: ["DiMyPaymentTypes"]),
        .library(name: "DiMyMintClient", targets: ["DiMyMintClient"]),
        .library(name: "DiMyWalletCell", targets: ["DiMyWalletCell"]),
        .library(name: "DiMyAccessCell", targets: ["DiMyAccessCell"]),
        .library(name: "DiMyCellProtocolCells", targets: ["DiMyCellProtocolCells"]),
        .library(name: "DiMyMicropayments", targets: ["DiMyMicropayments"])
    ],
    dependencies: [
        cellProtocolDependency,
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0")
    ],
    targets: [
        .target(
            name: "DiMyPaymentTypes",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "DiMyMintClient",
            dependencies: ["DiMyPaymentTypes"]
        ),
        .target(
            name: "DiMyWalletCell",
            dependencies: ["DiMyPaymentTypes", "DiMyMintClient"]
        ),
        .target(
            name: "DiMyAccessCell",
            dependencies: ["DiMyPaymentTypes", "DiMyMintClient"]
        ),
        .target(
            name: "DiMyCellProtocolCells",
            dependencies: [
                "DiMyPaymentTypes",
                "DiMyMintClient",
                "DiMyWalletCell",
                "DiMyAccessCell",
                .product(name: "CellBase", package: "CellProtocol")
            ]
        ),
        .target(
            name: "DiMyMicropayments",
            dependencies: [
                "DiMyPaymentTypes",
                "DiMyMintClient",
                "DiMyWalletCell",
                "DiMyAccessCell",
                "DiMyCellProtocolCells"
            ]
        ),
        .testTarget(
            name: "DiMyWalletCellTests",
            dependencies: ["DiMyWalletCell", "DiMyMintClient", "DiMyPaymentTypes"]
        ),
        .testTarget(
            name: "DiMyAccessCellTests",
            dependencies: ["DiMyAccessCell", "DiMyWalletCell", "DiMyMintClient", "DiMyPaymentTypes"]
        ),
        .testTarget(
            name: "DiMyPaymentTypesTests",
            dependencies: ["DiMyPaymentTypes"]
        ),
        .testTarget(
            name: "DiMyIssuerSegregationTests",
            dependencies: [
                "DiMyWalletCell",
                "DiMyAccessCell",
                "DiMyMintClient",
                "DiMyPaymentTypes",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .testTarget(
            name: "DiMyCellProtocolCellsTests",
            dependencies: [
                "DiMyCellProtocolCells",
                .product(name: "CellBase", package: "CellProtocol")
            ]
        )
    ]
)
