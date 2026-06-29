import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import CrumbArt

/// Frames raw app screenshots into store-style marketing cards via ``MarketingFrame``.
///
/// Usage:
///   `swift run --package-path CrumbArt crumb-art-market <screenshots-dir> <out-dir>`
/// Renders a fixed set of slides for whichever source screenshots are present.
@main
struct MarketRender {
    struct Slide {
        let file: String
        let headline: String
        let subhead: String
        let accent: Color
    }

    static let slides: [Slide] = [
        Slide(file: "01-onboarding.png",
              headline: "It learns your\ntaste first.",
              subhead: "So Crumb curates for you, not the average shopper.",
              accent: ArtPalette.pine),
        Slide(file: "new-missions.png",
              headline: "Hand it a\nmission.",
              subhead: "Crumb does the legwork and brings you a kit.",
              accent: ArtPalette.pine),
        Slide(file: "new-curate.png",
              headline: "A deck made\nfor you.",
              subhead: "Swipe the kit together — in Crumb's own voice.",
              accent: ArtPalette.ochre),
        Slide(file: "new-kit.png",
              headline: "That's a kit.",
              subhead: "Everything gathered, ready to check out.",
              accent: ArtPalette.pine),
    ]

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: crumb-art-market <screenshots-dir> <out-dir>\n".utf8))
            exit(2)
        }
        let inDir = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var made = 0
        for (i, slide) in slides.enumerated() {
            let src = inDir.appendingPathComponent(slide.file)
            guard let ns = NSImage(contentsOf: src) else {
                FileHandle.standardError.write(Data("• skip \(slide.file) (not found)\n".utf8))
                continue
            }
            let view = MarketingFrame(
                shot: Image(nsImage: ns),
                headline: slide.headline,
                subhead: slide.subhead,
                accent: slide.accent
            )
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            renderer.isOpaque = true
            guard let cg = renderer.cgImage else {
                FileHandle.standardError.write(Data("✗ render failed for \(slide.file)\n".utf8))
                continue
            }
            let out = outDir.appendingPathComponent(String(format: "market-%02d.png", i + 1))
            if writePNG(cg, to: out) {
                print("✓ \(out.lastPathComponent)  \(cg.width)×\(cg.height)px  ← \(slide.file)")
                made += 1
            }
        }
        print("Done. \(made) marketing card(s) → \(outDir.path)")
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
