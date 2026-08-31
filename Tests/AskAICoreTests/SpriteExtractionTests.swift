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

@Suite("Shared scale across sheets")
struct SharedScaleTests {

    /// A cell holding a character of the given height, on white.
    private func sheet(columns: Int, rows: Int, characterHeight: Int) -> PixelBitmap {
        var bitmap = PixelBitmap(width: columns * 200, height: rows * 200)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width { bitmap[x, y] = (255, 255, 255, 255) }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let top = row * 200 + (200 - characterHeight) / 2
                for y in top..<(top + characterHeight) {
                    for x in (column * 200 + 80)..<(column * 200 + 120) {
                        bitmap[x, y] = (20, 20, 20, 255)
                    }
                }
            }
        }
        return bitmap
    }

    private func opaqueHeight(_ frame: PixelBitmap) -> Int {
        var top = -1, bottom = -1
        for y in 0..<frame.height {
            for x in 0..<frame.width where frame[x, y].a > 0 {
                if top < 0 { top = y }
                bottom = y
                break
            }
        }
        return top < 0 ? 0 : bottom - top + 1
    }

    /// The defect this exists to prevent: cut alone, a 100px character and a
    /// 150px character both fill their frame, so the same character appears at
    /// two sizes depending on which mood is showing.
    @Test("cutting sheets separately makes equal characters look different")
    func separateCuttingIsInconsistent() throws {
        let short = try SpriteExtractor.frames(
            from: sheet(columns: 2, rows: 1, characterHeight: 100),
            columns: 2, rows: 1, options: .init(targetHeight: 120))
        let tall = try SpriteExtractor.frames(
            from: sheet(columns: 2, rows: 1, characterHeight: 150),
            columns: 2, rows: 1, options: .init(targetHeight: 120))
        // Both fill their frame: the size difference has been erased.
        #expect(opaqueHeight(short[0]) == opaqueHeight(tall[0]))
    }

    @Test("cutting sheets together preserves their relative sizes")
    func sharedScaleIsConsistent() throws {
        let cut = try SpriteExtractor.frames(
            fromSheets: [
                (sheet(columns: 2, rows: 1, characterHeight: 100), 2, 1, []),
                (sheet(columns: 2, rows: 1, characterHeight: 150), 2, 1, []),
            ],
            options: .init(targetHeight: 120))

        let short = opaqueHeight(cut[0][0])
        let tall = opaqueHeight(cut[1][0])
        #expect(tall > short, "the taller character should still be taller")
        // 150/100 = 1.5, within a pixel or two of rounding.
        let ratio = Double(tall) / Double(short)
        #expect(abs(ratio - 1.5) < 0.1, "ratio was \(ratio)")
    }

    @Test("every frame of every sheet shares one canvas size")
    func canvasIsShared() throws {
        let cut = try SpriteExtractor.frames(
            fromSheets: [
                (sheet(columns: 3, rows: 2, characterHeight: 100), 3, 2, []),
                (sheet(columns: 2, rows: 2, characterHeight: 150), 2, 2, []),
            ],
            options: .init(targetHeight: 132))
        let sizes = Set(cut.flatMap { $0 }.map { "\($0.width)x\($0.height)" })
        #expect(sizes.count == 1, "frames came out at \(sizes)")
    }

    @Test("characters sit on the canvas floor rather than floating")
    func bottomAligned() throws {
        let cut = try SpriteExtractor.frames(
            fromSheets: [
                (sheet(columns: 1, rows: 1, characterHeight: 80), 1, 1, []),
                (sheet(columns: 1, rows: 1, characterHeight: 160), 1, 1, []),
            ],
            options: .init(targetHeight: 120))
        // The short character's feet should be at the bottom, not mid-air.
        let shortFrame = cut[0][0]
        var lastOpaqueRow = -1
        for y in 0..<shortFrame.height {
            for x in 0..<shortFrame.width where shortFrame[x, y].a > 0 {
                lastOpaqueRow = y
                break
            }
        }
        #expect(lastOpaqueRow >= shortFrame.height - 2,
                "character floats: last opaque row \(lastOpaqueRow) of \(shortFrame.height)")
    }

    @Test("an empty sheet list returns nothing rather than throwing")
    func emptyInput() throws {
        #expect(try SpriteExtractor.frames(fromSheets: []).isEmpty)
    }

    @Test("one sheet through the shared path matches the single-sheet path")
    func singleSheetUnchanged() throws {
        let bitmap = sheet(columns: 3, rows: 2, characterHeight: 120)
        let options = SpriteExtractor.Options(targetHeight: 132)
        let alone = try SpriteExtractor.frames(
            from: bitmap, columns: 3, rows: 2, options: options)
        let together = try SpriteExtractor.frames(
            fromSheets: [(bitmap, 3, 2, [])], options: options)
        #expect(alone == together[0])
    }
}
