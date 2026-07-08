// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "LibBchatUtil",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(name: "BchatUtil", targets: ["BchatUtil"])
    ],
    targets: [
        .binaryTarget(
            name: "BchatUtil",
            url: "https://github.com/Beldex-Coin/libbchat-util-spm/releases/download/1.0.0/libbchat-util.xcframework.zip",
            checksum: "PLACEHOLDER_UNTIL_FIRST_BUILD"
        )
    ]
)
