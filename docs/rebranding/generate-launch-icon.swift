// Run with: xcrun swift docs/rebranding/generate-launch-icon.swift
// Export the app's Icon Composer document for the launch and About screens.
// The native renderer supplies the icon mask, lighting, and dark appearance.
// LaunchScreen.storyboard and LaunchView share the same generated image set.
import Foundation

struct ArtworkError: Error, CustomStringConvertible {
    let description: String
}

func run(_ executable: URL, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw ArtworkError(description: "\(executable.lastPathComponent) failed:\n\(text)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func generateBrandArtwork() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let assets = root.appendingPathComponent("PocketSword/Images.xcassets")
    let source = root.appendingPathComponent("SimpleScripture App Icon.icon")
    let developerDirectory = try run(
        URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"]
    )
    // xcrun's ictool is the asset compiler; image export is provided by the
    // executable bundled inside Icon Composer.
    let renderer = URL(fileURLWithPath: developerDirectory)
        .deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
    let files = FileManager.default
    guard files.fileExists(atPath: source.appendingPathComponent("icon.json").path),
          files.isExecutableFile(atPath: renderer.path) else {
        throw ArtworkError(description: "The app's .icon document and Xcode's Icon Composer are required.")
    }
    let staging = files.temporaryDirectory
        .appendingPathComponent("SimpleScripture-brand-\(UUID().uuidString)")
    try files.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: staging) }

    let imageSets = [
        (name: "LaunchIcon", filename: "LaunchIcon", points: 128),
        (name: "SimpleScriptureAbout", filename: "SimpleScripture", points: 112)
    ]
    for imageSet in imageSets {
        let directory = staging.appendingPathComponent("\(imageSet.name).imageset")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var images: [[String: Any]] = []
        for appearance in ["Default", "Dark"] {
            for scale in 1...3 {
                let appearanceSuffix = appearance == "Dark" ? "-Dark" : ""
                let scaleSuffix = scale == 1 ? "" : "@\(scale)x"
                let filename = "\(imageSet.filename)\(appearanceSuffix)\(scaleSuffix).png"
                _ = try run(renderer, arguments: [
                    source.path,
                    "--export-image", "--output-file", directory.appendingPathComponent(filename).path,
                    "--platform", "iOS", "--rendition", appearance,
                    "--width", "\(imageSet.points)", "--height", "\(imageSet.points)",
                    "--scale", "\(scale)", "--design-generation", "27"
                ])
                var image: [String: Any] = [
                    "filename": filename, "idiom": "universal", "scale": "\(scale)x"
                ]
                if appearance == "Dark" {
                    image["appearances"] = [["appearance": "luminosity", "value": "dark"]]
                }
                images.append(image)
            }
        }
        let manifest: [String: Any] = [
            "images": images,
            "info": ["author": "xcode", "version": 1]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: directory.appendingPathComponent("Contents.json"))
    }
    // Finish all exports before replacing any of the checked-in artwork.
    for imageSet in imageSets {
        let directory = staging.appendingPathComponent("\(imageSet.name).imageset")
        let destination = assets.appendingPathComponent("\(imageSet.name).imageset")
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try Data(contentsOf: file).write(
                to: destination.appendingPathComponent(file.lastPathComponent), options: .atomic
            )
        }
        print("Updated \(imageSet.name): Default and Dark at 1x, 2x, and 3x.")
    }
}

try generateBrandArtwork()
