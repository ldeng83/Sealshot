// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WebRTCAPM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WebRTCAPM", targets: ["WebRTCAPM"]),
    ],
    targets: [
        // Prebuilt universal (arm64 + x86_64) static lib wrapped as an
        // xcframework. Produced from webrtc-audio-processing v1.3 — see README.
        .binaryTarget(
            name: "WebRTCAPMBinary",
            path: "Frameworks/WebRTCAPM.xcframework"
        ),
        // C/C++ target: plain-C ABI shim that bridges to the prebuilt lib.
        .target(
            name: "CWebRTCAPM",
            dependencies: ["WebRTCAPMBinary"],
            // Only include/cwebrtc_apm.h is the public (modulemap) header.
            // The vendored webrtc/abseil headers live under vendor/ and are
            // reached via an explicit -I so they are NOT re-exported to Swift.
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("vendor/webrtc"),  // for "modules/..."
                .headerSearchPath("vendor"),          // for "absl/..."
                // Match the flags the upstream meson build uses.
                .define("WEBRTC_POSIX"),
                .define("WEBRTC_MAC"),
            ],
            linkerSettings: [
                // The static archive itself is linked via the WebRTCAPMBinary
                // dependency above; here we add its required system libs.
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "WebRTCAPM",
            dependencies: ["CWebRTCAPM"]
        ),
        .testTarget(
            name: "WebRTCAPMTests",
            dependencies: ["WebRTCAPM"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
