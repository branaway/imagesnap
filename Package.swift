// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "imagesnap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "snapcam", targets: ["imagesnap"]),
    ],
    targets: [
        .executableTarget(
            name: "imagesnap",
            path: ".",
            exclude: ["README.md", "ImageSnap.entitlements", "Info.plist", "ImageSnap.xcodeproj", "Makefile", "snapcam"],
            sources: ["main.swift"],
            linkerSettings: [
                // Avoid "NSKVONotifying_AVCapturePhotoOutput not linked" runtime warning on macOS (AVFoundation KVO quirk)
                .unsafeFlags(["-Xlinker", "-ObjC"]),
            ]
        ),
    ]
)
