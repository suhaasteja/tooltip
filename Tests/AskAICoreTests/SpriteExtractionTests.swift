import Testing
import Foundation
@testable import AskAICore

/// Builds synthetic sheets, so the extractor's rules can be asserted rather than
/// eyeballed. Every case here is a shape that broke, or nearly broke, a real
/// generated sheet.
private struct SheetBuilder {
    var bitmap: PixelBitmap

    init(width: Int, height: Int, background: UInt8 = 255) {
        bitmap = PixelBitmap(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                bitmap[x, y] = (background, background, background, 255)
            }
        }
    }

    mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int,
                       _ colour: (UInt8, UInt8, UInt8)) {
        for yy in y..<(y + h) {
            for xx in x..<(x + w) where xx >= 0 && yy >= 0
                && xx < bitmap.width && yy < bitmap.height {
                bitmap[xx, yy] = (colour.0, colour.1, colour.2, 255)
            }
        }
    }

    /// A hollow rectangle, as image models draw around each cell.
    mutating func stroke(_ x: Int, _ y: Int, _ w: Int, _ h: Int,
                         _ colour: (UInt8, UInt8, UInt8)) {
        fill(x, y, w, 2, colour)
        fill(x, y + h - 2, w, 2, colour)
        fill(x, y, 2, h, colour)
        fill(x + w - 2, y, 2, h, colour)
    }
}

private let dark: (UInt8, UInt8, UInt8) = (20, 20, 20)

@Suite("Sprite extraction")
struct SpriteExtractionTests {

    private func opaqueCount(_ frame: PixelBitmap) -> Int {
        stride(from: 3, to: frame.pixels.count, by: 4).reduce(0) {
            $0 + (frame.pixels[$1] > 0 ? 1 : 0)
        }
    }

    private func isOpaque(_ frame: PixelBitmap, _ x: Int, _ y: Int) -> Bool {
        frame[x, y].a > 0
    }

    /// A plus sign. Needed because a solid rectangle's bounding box *is* the
    /// character, so its frame has no transparent corner to assert on — the
    /// crop is tight by design.
    private func cross(_ builder: inout SheetBuilder, x: Int, y: Int, size: Int) {
        let third = size / 3
        builder.fill(x + third, y, third, size, dark)
        builder.fill(x, y + third, size, third, dark)
    }

    @Test("slices a plain grid into one frame per cell")
    func slicesGrid() throws {
        var sheet = SheetBuilder(width: 300, height: 200)
        for row in 0..<2 {
            for column in 0..<3 {
                sheet.fill(column * 100 + 30, row * 100 + 30, 40, 40, dark)
            }
        }
        let frames = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 3, rows: 2,
            options: .init(targetHeight: 40))
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { $0.height == 40 })
        #expect(frames.allSatisfy { self.opaqueCount($0) > 0 })
    }

    @Test("corners are transparent and the character is opaque")
    func backgroundIsCleared() throws {
        var sheet = SheetBuilder(width: 100, height: 100)
        cross(&sheet, x: 20, y: 20, size: 60)
        let frame = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 1, rows: 1, options: .init(targetHeight: 60))[0]
        let cornerClear = !isOpaque(frame, 0, 0)
        let centreSolid = isOpaque(frame, frame.width / 2, frame.height / 2)
        #expect(cornerClear, "the corner outside the cross should be transparent")
        #expect(centreSolid, "the centre of the cross should be opaque")
    }

    /// The reason flood fill was abandoned. Both image models draw these even
    /// when the prompt forbids it.
    @Test("a drawn cell border is rejected, not treated as the character")
    func borderRejected() throws {
        var sheet = SheetBuilder(width: 200, height: 200)
        sheet.stroke(4, 4, 192, 192, dark)      // the border
        // Deliberately not square: the crop follows the character, so a frame
        // half as wide as it is tall proves the border was not what got cropped.
        sheet.fill(90, 60, 20, 80, dark)
        let frame = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 1, rows: 1, options: .init(targetHeight: 80))[0]
        let width = frame.width
        #expect(width == 20, "cropped to \(width)x80; the border was kept")
    }

    @Test("a cell holding only a border yields no character")
    func borderOnlyCellRejected() {
        var sheet = SheetBuilder(width: 200, height: 200)
        sheet.stroke(4, 4, 192, 192, dark)
        let found = SpriteExtractor.character(
            in: sheet.bitmap,
            cell: .init(x: 0, y: 0, width: 200, height: 200),
            options: .init())
        #expect(found == nil)
    }

    @Test("every cell being a border throws rather than returning junk")
    func allBordersThrows() {
        var sheet = SheetBuilder(width: 200, height: 100)
        sheet.stroke(2, 2, 96, 96, dark)
        sheet.stroke(102, 2, 96, 96, dark)
        #expect(throws: SpriteExtractor.ExtractionError.noCharacters) {
            try SpriteExtractor.frames(from: sheet.bitmap, columns: 2, rows: 1)
        }
    }

    /// The PNG model tints its background — measured at 29% pure white — so a
    /// threshold tuned for 255 would treat the whole cell as ink.
    @Test("a tinted background is still recognised as background")
    func tintedBackground() throws {
        var sheet = SheetBuilder(width: 100, height: 100, background: 232)
        cross(&sheet, x: 20, y: 20, size: 60)
        let frame = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 1, rows: 1,
            options: .init(backgroundThreshold: 200, targetHeight: 60))[0]
        let cornerClear = !isOpaque(frame, 0, 0)
        let centreSolid = isOpaque(frame, frame.width / 2, frame.height / 2)
        #expect(cornerClear, "tinted background was treated as ink")
        #expect(centreSolid)
    }

    /// Without hole filling the guitarist's eyes and the light face of his guitar
    /// are punched through, because they are background-coloured pixels inside him.
    @Test("light pixels enclosed by the character are kept")
    func interiorHolesPreserved() throws {
        var sheet = SheetBuilder(width: 100, height: 100)
        sheet.fill(20, 20, 60, 60, dark)
        sheet.fill(40, 40, 20, 20, (255, 255, 255))   // a hole in the middle
        let frame = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 1, rows: 1, options: .init(targetHeight: 60))[0]
        let centreSolid = isOpaque(frame, frame.width / 2, frame.height / 2)
        #expect(centreSolid, "interior hole was punched through")
    }

    /// A character is frequently more than one blob. Keeping only the biggest
    /// would silently amputate a detached limb or held object.
    @Test("a detached part of the character is kept")
    func detachedPartKept() throws {
        var sheet = SheetBuilder(width: 120, height: 120)
        sheet.fill(30, 20, 50, 50, dark)      // body
        sheet.fill(40, 80, 30, 20, dark)      // detached legs, no connection
        let found = SpriteExtractor.character(
            in: sheet.bitmap, cell: .init(x: 0, y: 0, width: 120, height: 120),
            options: .init())
        let bounds = try #require(found?.bounds)
        // Bounds must reach the detached piece, not stop at the body.
        #expect(bounds.y + bounds.height >= 99, "detached part was dropped: \(bounds)")
    }

    @Test("specks far smaller than the character are dropped as noise")
    func noiseDropped() throws {
        var sheet = SheetBuilder(width: 120, height: 120)
        sheet.fill(30, 30, 50, 50, dark)      // character
        sheet.fill(110, 5, 2, 2, dark)        // a speck
        let found = SpriteExtractor.character(
            in: sheet.bitmap, cell: .init(x: 0, y: 0, width: 120, height: 120),
            options: .init())
        let bounds = try #require(found?.bounds)
        #expect(bounds.x + bounds.width <= 85, "speck widened the bounds: \(bounds)")
    }

    /// The property that stops playback jittering: every frame shares one crop,
    /// so a character that moves within its cell still lands consistently.
    @Test("all frames share one crop and come out the same size")
    func framesShareACrop() throws {
        var sheet = SheetBuilder(width: 200, height: 100)
        sheet.fill(20, 20, 30, 60, dark)      // tall, left
        sheet.fill(120, 40, 60, 20, dark)     // short, wide, right
        let frames = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 2, rows: 1, options: .init(targetHeight: 60))
        #expect(frames[0].width == frames[1].width)
        #expect(frames[0].height == frames[1].height)
    }

    @Test("a grid finer than the image is rejected")
    func gridTooFine() {
        let sheet = SheetBuilder(width: 4, height: 4)
        #expect(throws: SpriteExtractor.ExtractionError.gridTooFine) {
            try SpriteExtractor.frames(from: sheet.bitmap, columns: 8, rows: 8)
        }
    }

    @Test("keep selects a subset of cells, in the order given")
    func keepSubset() throws {
        var sheet = SheetBuilder(width: 300, height: 100)
        for column in 0..<3 { sheet.fill(column * 100 + 30, 30, 40, 40, dark) }
        let frames = try SpriteExtractor.frames(
            from: sheet.bitmap, columns: 3, rows: 1, keep: [2, 0],
            options: .init(targetHeight: 40))
        #expect(frames.count == 2)
    }

    @Test("block pitch is nil when there is no repeating structure")
    func noBlockPitch() {
        var sheet = SheetBuilder(width: 100, height: 100)
        sheet.fill(20, 20, 60, 60, dark)      // one solid block, no edges inside
        let pitch = SpriteExtractor.blockPitch(
            in: sheet.bitmap,
            cell: .init(x: 0, y: 0, width: 100, height: 100),
            crop: .init(x: 0, y: 0, width: 100, height: 100),
            options: .init())
        #expect(pitch == nil)
    }
}
