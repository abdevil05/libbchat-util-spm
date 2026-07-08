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
            url: "https://github.com/abdevil05/libbchat-util-spm/releases/download/1.1.0/libbchat-util.xcframework.zip",
            checksum: "0098ebd0dcd4579e62a91b45f82409751a485ae710bbc94621a2ff4d7c0bd107"
        )
    ]
)
