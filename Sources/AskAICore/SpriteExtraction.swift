import Foundation
import CoreGraphics

/// A mutable RGBA8 bitmap, premultiplied-last to match what CoreGraphics hands
/// back so no conversion is needed on the way in or out.
public struct PixelBitmap: Equatable {
    public var pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
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
}

/// Turns a sprite sheet into aligned, transparent frames.
///
/// The approach is the third one tried; the two that failed are recorded in
/// NOTES.md so they are not re-attempted. Generated sheets defeat the obvious
/// methods because image models draw visible cell borders — even when told not
/// to — and those borders enclose each cell, so any flood fill starting at an
/// edge cannot reach the background inside.
public enum SpriteExtractor {

    public struct Options: Equatable, Sendable {
        /// A pixel is background when every channel is at least this.
        ///
        /// Not 250. Generated backgrounds are not pure white: the JPEG model
        /// rings around outlines and the PNG model tints the background outright
        /// (measured at 29% pure white).
        public var backgroundThreshold: UInt8

        /// A component covering at least this fraction of the cell in *both*
        /// axes is the drawn border, not a character, and is rejected.
        public var borderRejectFraction: Double

        /// Components smaller than this fraction of the biggest one are treated
        /// as noise and dropped.
        ///
        /// Not zero, and not "keep only the biggest". Keeping only the biggest
        /// truncated a generated robot's legs, which were a separate component
        /// from its body — a character is frequently more than one blob, and
        /// silently amputating it is worse than keeping a speck of dust.
        public var noiseFraction: Double

        /// Output frame height in pixels. Frames are 2x for Retina.
        public var targetHeight: Int

        /// Sample at detected pixel-art block centres rather than at naive
        /// nearest-neighbour positions.
        ///
        /// Worth ~2.5% fewer stray colours on a JPEG source (197 vs 202 buckets
        /// measured).
        public var snapToPixelGrid: Bool

        public init(
            backgroundThreshold: UInt8 = 200,
            borderRejectFraction: Double = 0.92,
            noiseFraction: Double = 0.02,
            targetHeight: Int = 132,
            snapToPixelGrid: Bool = false
        ) {
            self.backgroundThreshold = backgroundThreshold
            self.borderRejectFraction = borderRejectFraction
            self.noiseFraction = noiseFraction
            self.targetHeight = targetHeight
            self.snapToPixelGrid = snapToPixelGrid
        }

        /// Settings used to cut the shipped character.
        ///
        /// Same as a generated character's, because the built-in one *is*
        /// generated — it just happens to be committed. The old value of 235
        /// belonged to the previous hand-drawn art and would leave a tinted
        /// background behind on these sheets.
        public static let vendored = Options(snapToPixelGrid: true)
    }

    public enum ExtractionError: Error, Equatable {
        /// The grid is larger than the image.
        case gridTooFine
        /// Every cell was empty, or held only a border.
        case noCharacters
    }

    /// An integer rectangle. `CGRect` would invite floating-point drift into
    /// what is strictly pixel indexing.
    public struct Box: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        var maxX: Int { x + width }
        var maxY: Int { y + height }
    }

    // MARK: - Entry point

    /// One sheet, measured but not yet rendered.
    ///
    /// Measuring and rendering are separate so several sheets can share one
    /// scale. See `frames(fromSheets:options:)`.
    public struct Measurement {
        let sheet: PixelBitmap
        let cells: [Box]
        let indices: [Int]
        let masks: [Int: [Bool]]
        /// Union of every character's bounds, in cell coordinates.
        public let crop: Box
    }

    /// Slices a sheet and returns one transparent, aligned frame per cell.
    ///
    /// - Parameter keep: cell indices in row-major order, or empty for all.
    public static func frames(
        from sheet: PixelBitmap,
        columns: Int,
        rows: Int,
        keep: [Int] = [],
        options: Options = Options()
    ) throws -> [PixelBitmap] {
        let measurement = try measure(
            from: sheet, columns: columns, rows: rows, keep: keep, options: options)
        return render(measurement, canvas: measurement.crop, options: options)
    }

    /// Cuts several sheets with **one shared scale**, so the character is the
    /// same size in every mood.
    ///
    /// Cutting each sheet alone gets this wrong in a way that is invisible until
    /// the moods are seen side by side. Every sheet scales its own union crop to
    /// `targetHeight`, so a character the model happened to draw at 213px in one
    /// sheet and 240px in another comes out the same height in both — which
    /// means the *same pose* ends up at two different sizes, and the character
    /// visibly grows when it starts thinking.
    ///
    /// Taking the union across all sheets and scaling everything by it keeps the
    /// relative sizes the model drew, which is what makes the moods look like one
    /// character.
    public static func frames(
        fromSheets sheets: [(bitmap: PixelBitmap, columns: Int, rows: Int, keep: [Int])],
        options: Options = Options()
    ) throws -> [[PixelBitmap]] {
        let measurements = try sheets.map {
            try measure(from: $0.bitmap, columns: $0.columns, rows: $0.rows,
                        keep: $0.keep, options: options)
        }
        guard let first = measurements.first else { return [] }
        // One canvas for every frame of every sheet: same scale, same size.
        let canvas = measurements.dropFirst().reduce(first.crop) {
            Box(x: 0, y: 0,
                width: max($0.width, $1.crop.width),
                height: max($0.height, $1.crop.height))
        }
        return measurements.map { render($0, canvas: canvas, options: options) }
    }

    public static func measure(
        from sheet: PixelBitmap,
        columns: Int,
        rows: Int,
        keep: [Int] = [],
        options: Options = Options()
    ) throws -> Measurement {

        let cellWidth = sheet.width / columns
        let cellHeight = sheet.height / rows
        guard cellWidth > 0, cellHeight > 0 else { throw ExtractionError.gridTooFine }

        var cells: [Box] = []
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(Box(x: column * cellWidth, y: row * cellHeight,
                                 width: cellWidth, height: cellHeight))
            }
        }
        let indices = keep.isEmpty ? Array(cells.indices) : keep

        var masks: [Int: [Bool]] = [:]
        var crop: Box?
        for index in indices {
            guard let found = character(in: sheet, cell: cells[index], options: options)
            else { continue }
            masks[index] = found.mask
            crop = crop.map { union($0, found.bounds) } ?? found.bounds
        }
        // One crop for every frame, so the character does not drift between them.
        guard let crop else { throw ExtractionError.noCharacters }

        return Measurement(sheet: sheet, cells: cells, indices: indices,
                           masks: masks, crop: crop)
    }

    /// Renders a measured sheet onto `canvas`.
    ///
    /// The scale comes from `canvas`, not from the sheet's own crop, which is
    /// what lets several sheets share one. The character keeps its position
    /// within its own crop and the extra room becomes transparent margin.
    static func render(
        _ m: Measurement, canvas: Box, options: Options
    ) -> [PixelBitmap] {
        m.indices.map { index in
            render(sheet: m.sheet, cell: m.cells[index], crop: m.crop,
                   canvas: canvas, mask: m.masks[index], options: options)
        }
    }

    // MARK: - Finding the character

    /// The character in a cell, as a mask plus its bounds.
    ///
    /// Not simply "the largest connected component". A character is frequently
    /// more than one blob — a generated robot's legs came back as a component
    /// separate from its body, and keeping only the biggest amputated it. So the
    /// rule is subtractive: drop what is definitely *not* character (the drawn
    /// cell border, and specks far smaller than the main mass) and keep the rest.
    ///
    /// Holes are then filled back in, so the mask covers everything the outline
    /// *encloses* rather than just its ink. Without that the shipped owl's pale
    /// chest and the lenses of its spectacles would be punched through, because
    /// they are background-coloured pixels sitting inside it.
    ///
    /// Public so a single cell can be inspected without running the whole
    /// pipeline, which is how the extractor is scored against real sheets.
    public static func character(
        in sheet: PixelBitmap, cell: Box, options: Options
    ) -> (mask: [Bool], bounds: Box)? {

        let w = cell.width, h = cell.height
        func isInk(_ cx: Int, _ cy: Int) -> Bool {
            let p = sheet[cell.x + cx, cell.y + cy]
            let t = options.backgroundThreshold
            return !(p.r >= t && p.g >= t && p.b >= t)
        }

        var visited = [Bool](repeating: false, count: w * h)
        var components: [(pixels: [Int], bounds: Box)] = []

        for sy in 0..<h {
            for sx in 0..<w where !visited[sy * w + sx] && isInk(sx, sy) {
                var queue = [sy * w + sx]
                visited[sy * w + sx] = true
                var head = 0
                var minX = sx, maxX = sx, minY = sy, maxY = sy

                while head < queue.count {
                    let i = queue[head]; head += 1
                    let x = i % w, y = i / w
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                    // 4-connected, iterative: these cells run to ~400x450 and a
                    // recursive fill would blow the stack.
                    if x + 1 < w, !visited[i + 1], isInk(x + 1, y) {
                        visited[i + 1] = true; queue.append(i + 1) }
                    if x > 0, !visited[i - 1], isInk(x - 1, y) {
                        visited[i - 1] = true; queue.append(i - 1) }
                    if y + 1 < h, !visited[i + w], isInk(x, y + 1) {
                        visited[i + w] = true; queue.append(i + w) }
                    if y > 0, !visited[i - w], isInk(x, y - 1) {
                        visited[i - w] = true; queue.append(i - w) }
                }

                components.append((queue, Box(x: minX, y: minY,
                                              width: maxX - minX + 1,
                                              height: maxY - minY + 1)))
            }
        }

        // Drop the drawn cell border: a component spanning nearly the whole cell
        // in both axes.
        let f = options.borderRejectFraction
        let notBorder = components.filter {
            !(Double($0.bounds.width) >= Double(w) * f
              && Double($0.bounds.height) >= Double(h) * f)
        }
        guard let largest = notBorder.max(by: { $0.pixels.count < $1.pixels.count })
        else { return nil }

        // Drop specks, keep limbs.
        let floor = Double(largest.pixels.count) * options.noiseFraction
        let kept = notBorder.filter { Double($0.pixels.count) >= floor }
        guard !kept.isEmpty else { return nil }

        var mask = [Bool](repeating: false, count: w * h)
        for component in kept {
            for i in component.pixels { mask[i] = true }
        }
        let bounds = kept.dropFirst().reduce(kept[0].bounds) { union($0, $1.bounds) }

        // Fill holes: within the kept bounds, anything NOT reachable from the
        // edge through background is enclosed, so keep it.
        let b = bounds
        var outside = [Bool](repeating: false, count: b.width * b.height)
        var queue: [Int] = []
        func pushOutside(_ bx: Int, _ by: Int) {
            guard bx >= 0, by >= 0, bx < b.width, by < b.height else { return }
            let j = by * b.width + bx
            guard !outside[j], !mask[(b.y + by) * w + (b.x + bx)] else { return }
            outside[j] = true
            queue.append(j)
        }
        for bx in 0..<b.width { pushOutside(bx, 0); pushOutside(bx, b.height - 1) }
        for by in 0..<b.height { pushOutside(0, by); pushOutside(b.width - 1, by) }
        var head = 0
        while head < queue.count {
            let j = queue[head]; head += 1
            let bx = j % b.width, by = j / b.width
            pushOutside(bx + 1, by); pushOutside(bx - 1, by)
            pushOutside(bx, by + 1); pushOutside(bx, by - 1)
        }
        for by in 0..<b.height {
            for bx in 0..<b.width where !outside[by * b.width + bx] {
                mask[(b.y + by) * w + (b.x + bx)] = true
            }
        }

        return (mask, bounds)
    }

    public static func union(_ a: Box, _ b: Box) -> Box {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        let maxX = max(a.maxX, b.maxX), maxY = max(a.maxY, b.maxY)
        return Box(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Rendering a frame

    private static func render(
        sheet: PixelBitmap, cell: Box, crop: Box, canvas: Box,
        mask: [Bool]?, options: Options
    ) -> PixelBitmap {
        let height = options.targetHeight
        // Scale from the shared canvas, so every sheet renders at one scale.
        let scale = Double(height) / Double(canvas.height)
        let outWidth = max(1, Int((Double(canvas.width) * scale).rounded()))
        var out = PixelBitmap(width: outWidth, height: height)

        // Centre this sheet's crop horizontally in the shared canvas, and sit it
        // on the canvas floor. Bottom-aligned rather than centred vertically:
        // characters stand on the ground, and a shorter pose should look like it
        // is crouching, not floating.
        let offsetX = (canvas.width - crop.width) / 2
        let offsetY = canvas.height - crop.height

        // Optionally align sampling to the generated art's pixel blocks. Falls
        // back silently when no clear pitch is found — a 2.5% improvement must
        // never be a failure path.
        let pitch = options.snapToPixelGrid
            ? blockPitch(in: sheet, cell: cell, crop: crop, options: options)
            : nil

        for oy in 0..<height {
            // Sample the centre of the output pixel: sampling its corner drifts
            // by half a pixel and shows up as the character shifting between
            // frames.
            //
            // Coordinates walk the *canvas*, then shift into this sheet's crop.
            // Anything landing outside the crop is canvas margin and stays
            // transparent, which is how a smaller sheet keeps its true size.
            let canvasY = sampleIndex(oy, scale: scale, limit: canvas.height, pitch: pitch)
            let sy = canvasY - offsetY
            for ox in 0..<outWidth {
                let canvasX = sampleIndex(ox, scale: scale, limit: canvas.width, pitch: pitch)
                let sx = canvasX - offsetX
                guard sx >= 0, sy >= 0, sx < crop.width, sy < crop.height else { continue }

                let cx = crop.x + sx, cy = crop.y + sy
                guard cx >= 0, cy >= 0, cx < cell.width, cy < cell.height else { continue }

                var pixel = sheet[cell.x + cx, cell.y + cy]
                let keep = mask?[cy * cell.width + cx] ?? false
                pixel.a = keep ? 255 : 0
                if !keep { pixel.r = 0; pixel.g = 0; pixel.b = 0 }
                out[ox, oy] = pixel
            }
        }
        return out
    }

    private static func sampleIndex(
        _ output: Int, scale: Double, limit: Int, pitch: Double?
    ) -> Int {
        let raw = (Double(output) + 0.5) / scale
        guard let pitch, pitch > 1 else { return min(limit - 1, Int(raw)) }
        // Snap to the centre of whichever source block this lands in.
        let block = (raw / pitch).rounded(.down)
        return min(limit - 1, max(0, Int((block + 0.5) * pitch)))
    }

    /// Estimates the pixel-art block size from horizontal edge spacing.
    ///
    /// Generated "pixel art" is a large image whose logical pixels are NxN
    /// blocks, and JPEG ringing lives at block boundaries. The gaps between
    /// sharp colour changes cluster at the block pitch, with weaker peaks at its
    /// multiples. Returns nil when there is no clear peak.
    public static func blockPitch(
        in sheet: PixelBitmap, cell: Box, crop: Box, options: Options
    ) -> Double? {
        var counts: [Int: Int] = [:]
        let y0 = crop.y + crop.height / 5, y1 = crop.y + crop.height * 4 / 5
        guard y1 > y0 else { return nil }

        for cy in stride(from: y0, to: y1, by: 3) {
            var lastEdge: Int?
            for cx in (crop.x + 1)..<crop.maxX {
                let a = sheet[cell.x + cx, cell.y + cy]
                let b = sheet[cell.x + cx - 1, cell.y + cy]
                let delta = abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g))
                    + abs(Int(a.b) - Int(b.b))
                guard delta > 40 else { continue }
                if let last = lastEdge {
                    let gap = cx - last
                    if gap >= 2 && gap <= 40 { counts[gap, default: 0] += 1 }
                }
                lastEdge = cx
            }
        }
        guard let mode = counts.max(by: { $0.value < $1.value }), mode.value >= 20
        else { return nil }
        // Average the mode with its immediate neighbours: the render is not on
        // an exact integer grid and lossy edges smear it either way.
        let near = counts.filter { abs($0.key - mode.key) <= 1 }
        let total = near.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }
        return Double(near.reduce(0) { $0 + $1.key * $1.value }) / Double(total)
    }
}
