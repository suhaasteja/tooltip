import Foundation

/// Text pulled off the pasteboard by a service invocation.
public struct Selection: Equatable {
    /// Cleaned-up text, ready to substitute into a prompt.
    public let text: String
    /// True when the original exceeded `SelectionExtractor.characterCap`.
    public let wasTruncated: Bool
    /// Length before cleaning, for logging.
    public let originalLength: Int

    public init(text: String, wasTruncated: Bool, originalLength: Int) {
        self.text = text
        self.wasTruncated = wasTruncated
        self.originalLength = originalLength
    }
}

/// Normalizes the raw pasteboard string into something worth sending to an LLM.
///
/// Deliberately pure and string-in/string-out: `NSPasteboard` stays in the app
/// target so the interesting rules are testable.
public enum SelectionExtractor {

    /// Upper bound on characters sent to the model. Selections beyond this are
    /// cut and marked rather than silently dropped or silently truncated.
    public static let characterCap = 8_000

    public static let truncationMarker = "\n\n[… selection truncated]"

    /// Cleans a raw pasteboard string.
    /// - Returns: `nil` when there is no usable text (missing, empty, or
    ///   whitespace-only), which callers surface as "no text selected".
    public static func extract(from raw: String?) -> Selection? {
        guard let raw else { return nil }
        let originalLength = raw.count

        let normalized = collapseWhitespace(in: raw)
        guard !normalized.isEmpty else { return nil }

        if normalized.count > characterCap {
            let cut = String(normalized.prefix(characterCap))
            return Selection(
                text: cut + truncationMarker,
                wasTruncated: true,
                originalLength: originalLength
            )
        }
        return Selection(text: normalized, wasTruncated: false, originalLength: originalLength)
    }

    /// Collapses runs of horizontal whitespace to a single space and runs of
    /// blank lines to a single blank line, then trims the ends.
    ///
    /// Paragraph breaks are preserved rather than flattened: selections are
    /// frequently multi-paragraph prose, and destroying that structure makes
    /// the model's job harder for no benefit. Only *runs* collapse.
    /// Line separators are normalized to `\n` so CRLF from Windows-origin text
    /// does not reach the model as stray `\r`.
    static func collapseWhitespace(in raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)

        var pendingNewlines = 0
        var pendingSpace = false
        var hasContent = false
        var previousWasCR = false

        for scalar in raw.unicodeScalars {
            if scalar == "\r" || scalar == "\n" {
                // CRLF is one line break, not two: skip the \n that follows a \r.
                if !(scalar == "\n" && previousWasCR) {
                    pendingNewlines += 1
                }
                previousWasCR = (scalar == "\r")
                pendingSpace = false
                continue
            }
            previousWasCR = false
            if isHorizontalWhitespace(scalar) {
                if hasContent { pendingSpace = true }
                continue
            }

            // A non-whitespace scalar: flush whatever separator is pending.
            if hasContent {
                if pendingNewlines > 0 {
                    // 1 newline stays a line break; 2+ collapse to one blank line.
                    out += pendingNewlines >= 2 ? "\n\n" : "\n"
                } else if pendingSpace {
                    out += " "
                }
            }
            pendingNewlines = 0
            pendingSpace = false
            hasContent = true
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Whitespace that is not a line break. Covers tabs, NBSP, and the Unicode
    /// space separators that PDFs and web pages love to emit.
    private static func isHorizontalWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\u{0B}", "\u{0C}", "\u{00A0}", "\u{200B}", "\u{FEFF}":
            return true
        default:
            // General category Zs (space separators) such as en/em quad.
            return scalar.properties.generalCategory == .spaceSeparator
        }
    }
}
