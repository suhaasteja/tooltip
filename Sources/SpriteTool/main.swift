// Slice sprite sheets into transparent, trimmed, panel-sized PNG frames.
//
// A SwiftPM target rather than a loose `swift scripts/…` script, because the
// extraction logic now lives in AskAICore and a script cannot import it. One
// implementation, shared with the in-app generator; this is only the file I/O
// around it.
//
// Usage:  swift run SpriteTool                    (re-cut the vendored sheets)
//         swift run SpriteTool <sheet.png> <cols> <rows> <name> <outdir>
//
// Output: Sources/AskAI/Sprites/<name>-<n>.png  (2x, for Retina)
//
// Output lives under the target directory, not the top-level Resources/, because
// SwiftPM only accepts resource paths inside the target it belongs to. Top-level
// Resources/ is for bundle-level files (Info.plist, entitlements) instead.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AskAICore

/// Where the vendored source sheets live. Outside this repo on purpose: the
/// generator is a separate project, and only the extracted frames are vendored.
let sourceRoot = ("~/Desktop/sprite-sheet-creator/assets" as NSString).expandingTildeInPath

struct Sheet {
    let file: String
    let columns: Int
    let rows: Int
    /// Output basename; frames are written as `<name>-0.png`, `<name>-1.png`, …
    let name: String
}

let vendored = [
    // Walk cycle: the loading loop. Row-major, 6 frames.
    Sheet(file: "sprite_1.png", columns: 3, rows: 2, name: "walk"),
    // Four distinct poses that map onto the non-loading panel states.
    // Row-major order is: crouch, airborne-arm-up, kneeling, standing.
    Sheet(file: "sprite_2.png", columns: 2, rows: 2, name: "pose"),
]

// MARK: - Image I/O

func loadBitmap(path: String) -> PixelBitmap? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }

    var bitmap = PixelBitmap(width: image.width, height: image.height)
    let drawn: Bool = bitmap.pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? bitmap : nil
}

func writePNG(_ bitmap: PixelBitmap, to path: String) -> Bool {
    var bitmap = bitmap
    let image: CGImage? = bitmap.pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
    guard let image,
          let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Driver

func cut(
    sheetPath: String, columns: Int, rows: Int, name: String,
    outputDir: String, options: SpriteExtractor.Options
) -> Int {
    guard let bitmap = loadBitmap(path: sheetPath) else {
        print("!! could not load \(sheetPath)")
        return 1
    }
    do {
        let frames = try SpriteExtractor.frames(
            from: bitmap, columns: columns, rows: rows, options: options)
        try? FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true)
        var failures = 0
        for (index, frame) in frames.enumerated() {
            let out = "\(outputDir)/\(name)-\(index).png"
            if writePNG(frame, to: out) {
                print("   \(name)-\(index).png  \(frame.width)x\(frame.height)")
            } else {
                print("!! failed to write \(out)")
                failures += 1
            }
        }
        print("==> \(URL(fileURLWithPath: sheetPath).lastPathComponent): \(frames.count) frames")
        return failures
    } catch {
        print("!! \(sheetPath): \(error)")
        return 1
    }
}

let args = Array(CommandLine.arguments.dropFirst())

// `evaluate <dir>` scores every sheet named in <dir>/manifest.json against
// PLAN-sprites.md Stage 2's pass criteria.
if args.first == "evaluate", args.count >= 2 {
    let dir = args[1]
    struct Entry: Decodable { let name: String; let columns: Int; let rows: Int
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            name = try c.decode(String.self)
            columns = try c.decode(Int.self)
            rows = try c.decode(Int.self)
        }
    }
    let data = try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/manifest.json"))
    let entries = try! JSONDecoder().decode([Entry].self, from: data)
    var passes = 0
    for entry in entries {
        guard let bitmap = loadBitmap(path: "\(dir)/\(entry.name).png") else {
            print("FAIL  \(entry.name)  (could not load)")
            continue
        }
        let result = SheetEvaluation.evaluate(
            sheet: bitmap, name: entry.name,
            columns: entry.columns, rows: entry.rows,
            options: SpriteExtractor.Options(snapToPixelGrid: true))
        SheetEvaluation.report(result)
        if result.passes { passes += 1 }
    }
    print("\n==> \(passes)/\(entries.count) sheets pass")
    exit(passes >= 4 ? 0 : 1)
}
let repoRoot = FileManager.default.currentDirectoryPath
var failures = 0

if args.count >= 5, let columns = Int(args[1]), let rows = Int(args[2]) {
    // Ad-hoc mode, for checking a freshly generated sheet.
    failures = cut(sheetPath: args[0], columns: columns, rows: rows, name: args[3],
                   outputDir: args[4],
                   options: SpriteExtractor.Options(snapToPixelGrid: true))
} else {
    // Re-cut the vendored sheets. `.vendored` options reproduce the committed
    // frames exactly; anything else here would be a silent asset change.
    let outputDir = "\(repoRoot)/Sources/AskAI/Sprites"
    for sheet in vendored {
        failures += cut(
            sheetPath: "\(sourceRoot)/\(sheet.file)",
            columns: sheet.columns, rows: sheet.rows, name: sheet.name,
            outputDir: outputDir, options: .vendored)
    }
    print("==> wrote frames to Sources/AskAI/Sprites")
}

if failures > 0 {
    print("!! \(failures) failure(s)")
    exit(1)
}
