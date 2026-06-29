import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import CrumbArt

/// Rasterizes the Crumb app icon to PNGs and writes them (plus an updated `Contents.json`)
/// into `Crumb/Resources/Assets.xcassets/AppIcon.appiconset`, so the icon stays reproducible
/// from the in-repo vector source.
///
/// Run from the app folder:
///   `swift run --package-path CrumbArt crumb-art-render`
/// Optionally pass a target `AppIcon.appiconset` path as the first argument.
@main
struct Render {
    struct Slot {
        let style: CrumbAppIcon.Style
        let pointSize: CGFloat
        let scale: CGFloat
        let filename: String
    }

    @MainActor
    static func main() {
        let outDir = resolveOutputDir()
        let fm = FileManager.default
        guard fm.fileExists(atPath: outDir.path) else {
            FileHandle.standardError.write(Data("✗ AppIcon.appiconset not found at \(outDir.path)\n".utf8))
            exit(1)
        }

        let slots = [
            Slot(style: .iOS, pointSize: 1024, scale: 1, filename: "AppIcon-iOS-1024.png"),
            Slot(style: .macOS, pointSize: 512, scale: 1, filename: "AppIcon-macOS-512.png"),
            Slot(style: .macOS, pointSize: 512, scale: 2, filename: "AppIcon-macOS-512@2x.png"),
        ]

        for slot in slots {
            guard let cg = renderIcon(style: slot.style, pointSize: slot.pointSize, scale: slot.scale) else {
                FileHandle.standardError.write(Data("✗ render failed for \(slot.filename)\n".utf8))
                exit(1)
            }
            let url = outDir.appendingPathComponent(slot.filename)
            guard writePNG(cg, to: url) else {
                FileHandle.standardError.write(Data("✗ write failed for \(slot.filename)\n".utf8))
                exit(1)
            }
            print("✓ \(slot.filename)  \(cg.width)×\(cg.height)px")
        }

        writeContents(into: outDir)
        print("✓ Contents.json updated")
        print("Done. Re-run `xcodegen generate` if the asset catalog membership changed.")
    }

    @MainActor
    static func renderIcon(style: CrumbAppIcon.Style, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let view = CrumbAppIcon(style: style)
            .frame(width: pointSize, height: pointSize)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// The iOS-universal + macOS @1x/@2x manifest pointing at the freshly written PNGs.
    static func writeContents(into dir: URL) {
        let json = """
        {
          "images" : [
            {
              "filename" : "AppIcon-iOS-1024.png",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            },
            {
              "filename" : "AppIcon-macOS-512.png",
              "idiom" : "mac",
              "scale" : "1x",
              "size" : "512x512"
            },
            {
              "filename" : "AppIcon-macOS-512@2x.png",
              "idiom" : "mac",
              "scale" : "2x",
              "size" : "512x512"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
        try? json.data(using: .utf8)?.write(to: dir.appendingPathComponent("Contents.json"))
    }

    /// `Crumb/Resources/Assets.xcassets/AppIcon.appiconset`, resolved from the first CLI
    /// argument or relative to this source file (three levels up from the tool sources).
    static func resolveOutputDir() -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1])
        }
        // .../crumb-llc-app/CrumbArt/Sources/crumb-art-render/Render.swift
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // crumb-art-render
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // CrumbArt
            .deletingLastPathComponent()  // crumb-llc-app
        return appRoot
            .appendingPathComponent("Crumb/Resources/Assets.xcassets/AppIcon.appiconset")
    }
}
