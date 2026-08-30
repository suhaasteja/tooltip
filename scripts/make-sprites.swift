// Slice sprite sheets into transparent, trimmed, panel-sized PNG frames.
//
// The source sheets are opaque white-background pixel art. Three things have to
// happen before they can be drawn in a transparent floating panel:
//
//   1. White -> alpha, by BFS flood fill inward from the border. A plain
//      "near-white is transparent" threshold cannot be used: the character has
//      white *inside* it (eyes, the guitar pickguard) which would be punched
//      out. Only white connected to the edge is background.
//   2. A single union bounding box across every frame of a sheet, applied to
//      all of them. Trimming each frame to its own bbox would re-centre the
//      character per frame and make it jitter during playback.
//   3. Nearest-neighbour downscale, so the pixel art stays hard-edged instead
//      of turning to mush.
//
// Usage:  swift scripts/make-sprites.swift
// Output: Sources/AskAI/Sprites/<name>-<n>.png  (2x, for Retina)
//
// Output lives under the target directory, not the top-level Resources/, because
// SwiftPM only accepts resource paths inside the target it belongs to. Top-level
// Resources/ is for bundle-level files (Info.plist, entitlements) instead.
//
// Re-run only when the source art changes; the output is committed.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

/// Where the source sheets live. Outside this repo on purpose: the generator is
/// a separate project, and only the extracted frames are vendored here.
let sourceRoot = ("~/Desktop/sprite-sheet-creator/assets" as NSString).expandingTildeInPath

struct Sheet {
    let file: String
    let columns: Int
    let rows: Int
    /// Output basename; frames are written as `<name>-0.png`, `<name>-1.png`, …
    let name: String
    /// Frame indices to keep, in output order. Empty means "all, in row order".
    let keep: [Int]
}

let sheets = [
    // Walk cycle: the loading loop. Row-major, 6 frames.
    Sheet(file: "sprite_1.png", columns: 3, rows: 2, name: "walk", keep: []),
    // Four distinct poses that map onto the non-loading panel states.
    // Row-major order is: crouch, airborne-arm-up, kneeling, standing.
    Sheet(file: "sprite_2.png", columns: 2, rows: 2, name: "pose", keep: []),
]

/// Output frame height in pixels. The view draws at half this (2x for Retina).
let targetHeight = 132
/// A pixel is "background white" if every channel is at least this.
let whiteThreshold: UInt8 = 235

// MARK: - Bitmap

/// A mutable RGBA8 bitmap. Premultiplied-last to match what CoreGraphics hands
/// back, so no conversion is needed on the way in or out.
struct Bitmap {
    var pixels: [UInt8]
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        get {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.r
            pixels[i + 1] = newValue.g
            pixels[i + 2] = newValue.b
            pixels[i + 3] = newValue.a
        }
    }

    func isWhite(_ x: Int, _ y: Int) -> Bool {
        let p = self[x, y]
        return p.r >= whiteThreshold && p.g >= whiteThreshold && p.b >= whiteThreshold
    }
}

func loadBitmap(path: String) -> Bitmap? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }

    var bitmap = Bitmap(width: image.width, height: image.height)
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue

    let drawn: Bool = bitmap.pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: info
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return drawn ? bitmap : nil
}

func writePNG(_ bitmap: Bitmap, to path: String) -> Bool {
    var bitmap = bitmap
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue

    let image: CGImage? = bitmap.pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
            space: space, bitmapInfo: info
        ) else { return nil }
        return ctx.makeImage()
    }
    guard let image else { return false }

    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Background removal

/// Clears white pixels reachable from the border, leaving interior white alone.
///
/// 4-connected BFS rather than recursion: these sheets are up to 1200x896 and a
/// recursive fill would blow the stack.
func clearBackground(_ bitmap: inout Bitmap) {
    var visited = [Bool](repeating: false, count: bitmap.width * bitmap.height)
    var queue: [(Int, Int)] = []

    func enqueue(_ x: Int, _ y: Int) {
        guard x >= 0, y >= 0, x < bitmap.width, y < bitmap.height else { return }
        let index = y * bitmap.width + x
        guard !visited[index], bitmap.isWhite(x, y) else { return }
        visited[index] = true
        queue.append((x, y))
    }

    for x in 0..<bitmap.width {
        enqueue(x, 0)
        enqueue(x, bitmap.height - 1)
    }
    for y in 0..<bitmap.height {
        enqueue(0, y)
        enqueue(bitmap.width - 1, y)
    }

    var head = 0
    while head < queue.count {
        let (x, y) = queue[head]
        head += 1
        bitmap[x, y] = (0, 0, 0, 0)
        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)
    }
}

// MARK: - Slicing

struct Rect { var x: Int; var y: Int; var width: Int; var height: Int }

/// Bounding box of non-transparent pixels, or nil if the region is empty.
func contentBounds(of bitmap: Bitmap, in cell: Rect) -> Rect? {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for y in cell.y..<(cell.y + cell.height) {
        for x in cell.x..<(cell.x + cell.width) where bitmap[x, y].a > 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard minX <= maxX else { return nil }
    // Relative to the cell, so it can be unioned across cells.
    return Rect(x: minX - cell.x, y: minY - cell.y,
                width: maxX - minX + 1, height: maxY - minY + 1)
}

func union(_ a: Rect, _ b: Rect) -> Rect {
    let minX = min(a.x, b.x), minY = min(a.y, b.y)
    let maxX = max(a.x + a.width, b.x + b.width)
    let maxY = max(a.y + a.height, b.y + b.height)
    return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// Crops `cell` offset by `crop` and scales it to `targetHeight`, nearest-neighbour.
func extract(from bitmap: Bitmap, cell: Rect, crop: Rect, scaledTo height: Int) -> Bitmap {
    let scale = Double(height) / Double(crop.height)
    let outWidth = max(1, Int((Double(crop.width) * scale).rounded()))
    var out = Bitmap(width: outWidth, height: height)

    for oy in 0..<height {
        // Nearest source row/column. Sampling the centre of the output pixel
        // avoids a half-pixel drift that would show up as the character
        // shifting by one pixel between frames.
        let sy = crop.y + min(crop.height - 1, Int((Double(oy) + 0.5) / scale))
        for ox in 0..<outWidth {
            let sx = crop.x + min(crop.width - 1, Int((Double(ox) + 0.5) / scale))
            out[ox, oy] = bitmap[cell.x + sx, cell.y + sy]
        }
    }
    return out
}

// MARK: - Main

let repoRoot = FileManager.default.currentDirectoryPath
let outputDir = "\(repoRoot)/Sources/AskAI/Sprites"
try? FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true)

var failures = 0

for sheet in sheets {
    let path = "\(sourceRoot)/\(sheet.file)"
    guard var bitmap = loadBitmap(path: path) else {
        print("!! could not load \(path)")
        failures += 1
        continue
    }

    clearBackground(&bitmap)

    let cellWidth = bitmap.width / sheet.columns
    let cellHeight = bitmap.height / sheet.rows

    var cells: [Rect] = []
    for row in 0..<sheet.rows {
        for column in 0..<sheet.columns {
            cells.append(Rect(x: column * cellWidth, y: row * cellHeight,
                              width: cellWidth, height: cellHeight))
        }
    }

    let indices = sheet.keep.isEmpty ? Array(cells.indices) : sheet.keep

    // One crop for every frame, so the character does not jitter between them.
    var crop: Rect?
    for index in indices {
        guard let bounds = contentBounds(of: bitmap, in: cells[index]) else { continue }
        crop = crop.map { union($0, bounds) } ?? bounds
    }
    guard let crop else {
        print("!! \(sheet.file): every frame was empty after background removal")
        failures += 1
        continue
    }

    for (output, index) in indices.enumerated() {
        let frame = extract(from: bitmap, cell: cells[index], crop: crop,
                            scaledTo: targetHeight)
        let out = "\(outputDir)/\(sheet.name)-\(output).png"
        if writePNG(frame, to: out) {
            print("   \(sheet.name)-\(output).png  \(frame.width)x\(frame.height)")
        } else {
            print("!! failed to write \(out)")
            failures += 1
        }
    }
    print("==> \(sheet.file): \(indices.count) frames, crop \(crop.width)x\(crop.height)")
}

if failures > 0 {
    print("!! \(failures) failure(s)")
    exit(1)
}
print("==> wrote frames to Sources/AskAI/Sprites")
