// Run with: xcrun swift docs/rebranding/generate-launch-icon.swift
// Bake the rounded mask into the launch artwork: launch storyboards cannot run
// custom code to clip a layer, and both launch surfaces must use the same image.
import AppKit
import SwiftUI

@MainActor
func generateLaunchIcon() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let assets = root.appendingPathComponent("PocketSword/Images.xcassets")
    let source = assets.appendingPathComponent(
        "SimpleScriptureAbout.imageset/SimpleScripture.png"
    )
    guard let image = NSImage(contentsOf: source) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let destination = assets.appendingPathComponent("LaunchIcon.imageset")
    try FileManager.default.createDirectory(
        at: destination, withIntermediateDirectories: true
    )

    for scale in 1...3 {
        let renderer = ImageRenderer(content:
            Image(nsImage: image)
                .resizable()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
        renderer.scale = CGFloat(scale)
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let suffix = scale == 1 ? "" : "@\(scale)x"
        try png.write(to: destination.appendingPathComponent("LaunchIcon\(suffix).png"))
    }
}

try MainActor.assumeIsolated {
    try generateLaunchIcon()
}
