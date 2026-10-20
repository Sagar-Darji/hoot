// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS("26.0")],         // same as Info.plist: Liquid Glass, and the bundled whisper.cpp needs it
    targets: [
        .executableTarget(
            name: "MeetingNotes",
            path: "Sources/MeetingNotes"
        )
    ]
)
