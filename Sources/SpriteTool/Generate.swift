import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AskAICore

/// `SpriteTool generate "<description>" <outdir>` — runs the real generation
/// job against the live API, using GEMINI_API_KEY from the environment.
///
/// Exists so the client can be exercised end to end before any UI depends on it,
/// and in particular so the reference-image path is proven: passing a generated
/// image back as `inline_data` is what holds character identity across sheets,
/// and it is a body shape the stub tests cannot validate.
enum GenerateCommand {

    static func encodePNG(_ bitmap: PixelBitmap) -> Data? {
        var bitmap = bitmap
        let image: CGImage? = bitmap.pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decodes whatever the model returned — JPEG from the pro model, PNG from
    /// flash — into the extractor's bitmap.
    static func decode(_ data: Data) -> PixelBitmap? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var bitmap = PixelBitmap(width: image.width, height: image.height)
        let ok: Bool = bitmap.pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? bitmap : nil
    }

    static func run(description: String, outputDir: String) async -> Int32 {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
              !key.isEmpty else {
            print("!! set GEMINI_API_KEY")
            return 1
        }

        let client = GeminiImageClient(apiKey: key)
        let job = SpriteGenerationJob(client: client, encoder: encodePNG)
        let started = Date()

        do {
            let output = try await job.run(
                id: "generated", name: description, description: description,
                decode: decode,
                progress: { step in
                    let elapsed = String(format: "%5.1fs", Date().timeIntervalSince(started))
                    print("[\(elapsed)] \(step.label)")
                })

            try FileManager.default.createDirectory(
                atPath: outputDir, withIntermediateDirectories: true)
            for (name, data) in output.frames {
                try data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
            }
            for (id, sheet) in output.sheets {
                let ext = sheet.mimeType.hasSuffix("png") ? "png" : "jpg"
                try sheet.data.write(to: URL(fileURLWithPath: "\(outputDir)/sheet-\(id).\(ext)"))
            }
            let manifest = try JSONEncoder().encode(output.set)
            try manifest.write(to: URL(fileURLWithPath: "\(outputDir)/manifest.json"))

            let total = String(format: "%.1f", Date().timeIntervalSince(started))
            print("==> \(output.frames.count) frames, \(output.sheets.count) sheets, \(total)s")
            print("==> moods: \(output.set.animations.keys.sorted().joined(separator: ", "))")
            return 0
        } catch let error as SpriteGeneratorError {
            print("!! \(error.userMessage)")
            return 1
        } catch {
            print("!! \(error)")
            return 1
        }
    }
}
