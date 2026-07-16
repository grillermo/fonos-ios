// NoteINV15: Notebook LLM settings compile into the shared workflow contract.
//
// Verifier: auto · Level: unit
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV15LLMNoteTests

import Testing
@testable import FonosApp

@MainActor
struct NoteINV15LLMNoteTests {
    @Test("Notebook output language is composed into the LLM system boundary")
    func outputLanguageIsComposedIntoSystemPrompt() throws {
        let notebook = NoteContainer(
            title: "Chinese output",
            llmModelOverride: "llm-profile",
            systemPrompt: "Polish the text.",
            outputLanguage: "zh-CN"
        )

        let recipe = NotebookPipeline.workflowRecipe(for: notebook)
        let llmID = try #require(recipe.definition.processors.last)
        let widget = try #require(recipe.catalog.widget(id: llmID))
        let system = try #require(widget.props["system"]?.stringValue)

        #expect(system.hasPrefix("Always respond in zh-CN."))
        #expect(system.contains("Polish the text."))
        #expect(widget.props["model_profile"]?.stringValue == "llm-profile")
        #expect(widget.props["output_language"]?.stringValue == "auto")
        #expect(widget.props["max_tokens"]?.intValue == 1_024)
    }

    @Test("Nil output language leaves the notebook prompt unchanged")
    func nilLanguageLeavesPromptUnchanged() throws {
        let notebook = NoteContainer(
            title: "Same language",
            systemPrompt: "Polish the text."
        )

        let recipe = NotebookPipeline.workflowRecipe(for: notebook)
        let llmID = try #require(recipe.definition.processors.last)
        let system = try #require(
            recipe.catalog.widget(id: llmID)?.props["system"]?.stringValue
        )

        #expect(system == "Polish the text.")
        #expect(!system.contains("Always respond"))
    }

    @Test("Empty language helper returns the prompt unchanged")
    func emptyLanguageReturnsPromptUnchanged() {
        #expect(
            NotebookPipeline.composeSystemPrompt(
                user: "Polish.", outputLanguage: ""
            ) == "Polish."
        )
        #expect(
            NotebookPipeline.composeSystemPrompt(
                user: "Polish.", outputLanguage: nil
            ) == "Polish."
        )
    }
}
