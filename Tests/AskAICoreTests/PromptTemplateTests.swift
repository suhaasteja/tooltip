import Testing
@testable import AskAICore

@Suite("Prompt templating")
struct PromptTemplateTests {

    @Test("substitutes the placeholder")
    func substitutes() {
        let out = PromptTemplate.render(
            template: "Explain: {{selection}}", selection: "photosynthesis")
        #expect(out == "Explain: photosynthesis")
    }

    @Test("substitutes every occurrence")
    func substitutesAll() {
        let out = PromptTemplate.render(
            template: "{{selection}} / {{selection}} / {{selection}}", selection: "x")
        #expect(out == "x / x / x")
    }

    @Test("a template with no placeholder appends rather than dropping the selection")
    func appendsWhenNoPlaceholder() {
        let out = PromptTemplate.render(template: "Summarise this.", selection: "some text")
        #expect(out == "Summarise this.\n\nsome text")
    }

    @Test("an empty or whitespace-only template falls back to the default")
    func emptyFallsBack() {
        for template in ["", "   \n\t "] {
            let out = PromptTemplate.render(template: template, selection: "abc")
            #expect(out == PromptTemplate.render(
                template: PromptTemplate.defaultTemplate, selection: "abc"))
            #expect(out.contains("abc"))
        }
    }

    @Test("a placeholder inside the selection is not re-expanded")
    func noRecursiveExpansion() {
        let out = PromptTemplate.render(
            template: "Explain: {{selection}}",
            selection: "the literal token {{selection}} here")
        #expect(out == "Explain: the literal token {{selection}} here")
    }

    @Test("braces in the selection survive untouched")
    func bracesSurvive() {
        let selection = "func f() { return {a: 1} } // {{not a token}}"
        let out = PromptTemplate.render(template: "Code: {{selection}}", selection: selection)
        #expect(out == "Code: \(selection)")
    }

    @Test("the default template includes the selection")
    func defaultTemplateWorks() {
        let out = PromptTemplate.render(
            template: PromptTemplate.defaultTemplate, selection: "mitochondria")
        #expect(out.hasSuffix("mitochondria"))
        #expect(out.contains("plain language"))
    }

    @Test("an empty selection still renders without crashing")
    func emptySelection() {
        let out = PromptTemplate.render(template: "Explain: {{selection}}", selection: "")
        #expect(out == "Explain: ")
    }
}
