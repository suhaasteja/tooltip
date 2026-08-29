import Foundation

/// Substitutes a selection into a user-editable prompt template.
public enum PromptTemplate {

    /// The token users write in their templates.
    public static let placeholder = "{{selection}}"

    public static let defaultTemplate =
        "Explain the following concisely, in plain language:\n\n\(placeholder)"

    /// System prompt sent alongside every request.
    public static let defaultSystem = """
        You are a concise assistant embedded in a macOS tooltip. Answer in plain \
        language. Keep responses short — a few sentences at most unless the user's \
        instruction explicitly asks for more. Do not restate the question, and do \
        not add preamble such as "Here is" or "Sure".
        """

    /// Builds the final prompt.
    ///
    /// Rules, in order:
    /// - An empty or whitespace-only template falls back to `defaultTemplate`.
    /// - Every occurrence of `{{selection}}` is replaced.
    /// - A template with no placeholder gets the selection appended rather than
    ///   dropped — losing the user's selection entirely is never the helpful
    ///   reading of a malformed template.
    ///
    /// Substitution is single-pass: `{{selection}}` appearing *inside* the
    /// selection is left alone rather than re-expanded.
    public static func render(template: String, selection: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? defaultTemplate : template

        guard effective.contains(placeholder) else {
            return effective.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + selection
        }
        return singlePassReplace(effective, placeholder: placeholder, with: selection)
    }

    /// Replaces every placeholder occurrence without rescanning inserted text.
    ///
    /// `String.replacingOccurrences` already behaves this way; this spells it
    /// out so the guarantee is explicit and testable rather than incidental.
    private static func singlePassReplace(
        _ source: String, placeholder: String, with replacement: String
    ) -> String {
        var result = ""
        var remainder = Substring(source)

        while let range = remainder.range(of: placeholder) {
            result += remainder[remainder.startIndex..<range.lowerBound]
            result += replacement
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }
}
