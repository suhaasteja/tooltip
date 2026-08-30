import Foundation
import CoreGraphics
import AskAICore

/// Scores a sheet against PLAN-sprites.md Stage 2's pass criteria.
///
/// Deliberately mechanical. The failure modes here — a character clipped by a
/// cell boundary, a border kept as a character, frames that drift — are all
/// things that look fine in a thumbnail, which is exactly how the "missing legs"
/// misdiagnosis in NOTES.md happened.
enum SheetEvaluation {

    struct Result {
        let name: String
        let cells: Int
        let charactersFound: Int
        let clipped: [Int]
        let backgroundCleared: [Int]
        let bounds: [SpriteExtractor.Box]

        var passes: Bool {
            charactersFound == cells
                && clipped.isEmpty
                && backgroundCleared.allSatisfy { $0 >= 95 }
        }
    }

    static func evaluate(
        sheet: PixelBitmap, name: String, columns: Int, rows: Int,
        options: SpriteExtractor.Options
    ) -> Result {
        let cellWidth = sheet.width / columns
        let cellHeight = sheet.height / rows

        var found = 0
        var clipped: [Int] = []
        var cleared: [Int] = []
        var boxes: [SpriteExtractor.Box] = []

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let cell = SpriteExtractor.Box(
                    x: column * cellWidth, y: row * cellHeight,
                    width: cellWidth, height: cellHeight)

                guard let result = SpriteExtractor.character(
                    in: sheet, cell: cell, options: options) else {
                    cleared.append(0)
                    continue
                }
                found += 1
                boxes.append(result.bounds)

                // Clipped: the character's bounds touch a cell edge, meaning it
                // probably continues into the neighbouring cell.
                let b = result.bounds
                if b.x <= 1 || b.y <= 1
                    || b.x + b.width >= cellWidth - 1
                    || b.y + b.height >= cellHeight - 1 {
                    clipped.append(index)
                }

                // How much of the cell ended up transparent, as a share of what
                // was background to begin with.
                var background = 0, transparent = 0
                let t = options.backgroundThreshold
                for cy in 0..<cellHeight {
                    for cx in 0..<cellWidth {
                        let p = sheet[cell.x + cx, cell.y + cy]
                        let isBackground = p.r >= t && p.g >= t && p.b >= t
                        if isBackground {
                            background += 1
                            if !result.mask[cy * cellWidth + cx] { transparent += 1 }
                        }
                    }
                }
                cleared.append(background == 0 ? 100 : transparent * 100 / background)
            }
        }

        return Result(name: name, cells: columns * rows, charactersFound: found,
                      clipped: clipped, backgroundCleared: cleared, bounds: boxes)
    }

    static func report(_ r: Result) {
        let verdict = r.passes ? "PASS" : "FAIL"
        print("\(verdict)  \(r.name)")
        print("   characters \(r.charactersFound)/\(r.cells)"
              + "   background cleared \(r.backgroundCleared.map(String.init).joined(separator: "/"))%")
        if !r.clipped.isEmpty {
            print("   !! clipped by a cell edge: cells \(r.clipped)")
        }
        if let first = r.bounds.first {
            let widths = r.bounds.map(\.width), heights = r.bounds.map(\.height)
            print("   bounds \(first.width)x\(first.height)"
                  + "  width \(widths.min()!)-\(widths.max()!)"
                  + "  height \(heights.min()!)-\(heights.max()!)")
        }
    }
}
