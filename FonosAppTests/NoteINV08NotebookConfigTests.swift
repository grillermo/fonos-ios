// NoteINV08: Active per-notebook workflow settings survive SwiftData round trips.
//
// Verifier: auto
// Level: unit (in-memory SwiftData ModelContainer)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV08NotebookConfigTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

// MARK: - In-memory container helper

@MainActor
private func makeConfigTestContainer() throws -> ModelContainer {
    let schema = Schema([NoteContainer.self, NoteEntry.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - Tests

@MainActor
struct NoteINV08NotebookConfigTests {

    @Test("New v2 fields default to expected values")
    func newFieldDefaults() throws {
        let modelContainer = try makeConfigTestContainer()
        let service = NoteService(modelContainer: modelContainer)
        let nb = try service.createNotebook(title: "Defaults")
        #expect(nb.systemPrompt == "")
        #expect(nb.sttLanguage == nil)
        #expect(nb.outputLanguage == nil)
        // Default flipped to true so users immediately see what STT heard,
        // separately from what the LLM produced.
        #expect(nb.showRawInline == true)
        #expect(nb.siriPhrase == nil)
    }

    @Test("v2 fields persist via updateNotebookConfigV2")
    func v2FieldsPersist() throws {
        let modelContainer = try makeConfigTestContainer()
        let service = NoteService(modelContainer: modelContainer)
        let nb = try service.createNotebook(title: "Persist")
        try service.updateNotebookConfigV2(
            nb.id,
            systemPrompt: "Be terse.",
            sttLanguage: .some("zh-CN"),
            outputLanguage: .some("en-US"),
            sttModelOverride: nil,
            llmModelOverride: nil,
            showRawInline: true,
            siriPhrase: .some("Note to Persist")
        )
        let fetched = try modelContainer.mainContext
            .fetch(FetchDescriptor<NoteContainer>())
            .first(where: { $0.id == nb.id })
        #expect(fetched?.systemPrompt == "Be terse.")
        #expect(fetched?.sttLanguage == "zh-CN")
        #expect(fetched?.outputLanguage == "en-US")
        #expect(fetched?.showRawInline == true)
        #expect(fetched?.siriPhrase == "Note to Persist")
    }

    @Test("updateNotebookConfigV2 leaves unspecified fields untouched")
    func v2PartialUpdate() throws {
        let modelContainer = try makeConfigTestContainer()
        let service = NoteService(modelContainer: modelContainer)
        let nb = try service.createNotebook(title: "Partial")
        try service.updateNotebookConfigV2(nb.id, systemPrompt: "First.")
        try service.updateNotebookConfigV2(nb.id, sttLanguage: .some("ja-JP"))

        let fetched = try modelContainer.mainContext
            .fetch(FetchDescriptor<NoteContainer>())
            .first(where: { $0.id == nb.id })
        #expect(fetched?.systemPrompt == "First.") // preserved
        #expect(fetched?.sttLanguage == "ja-JP")    // updated
    }

    @Test("updateNotebookConfigV2 can clear sttLanguage with .some(nil)")
    func v2ClearLanguage() throws {
        let modelContainer = try makeConfigTestContainer()
        let service = NoteService(modelContainer: modelContainer)
        let nb = try service.createNotebook(title: "Clear")
        try service.updateNotebookConfigV2(nb.id, sttLanguage: .some("zh-CN"))
        try service.updateNotebookConfigV2(nb.id, sttLanguage: .some(nil))

        let fetched = try modelContainer.mainContext
            .fetch(FetchDescriptor<NoteContainer>())
            .first(where: { $0.id == nb.id })
        #expect(fetched?.sttLanguage == nil)
    }

    @Test("v2 model overrides persist and can be cleared independently")
    func v2ModelOverridesPersistAndClear() throws {
        let modelContainer = try makeConfigTestContainer()
        let service = NoteService(modelContainer: modelContainer)
        let nb = try service.createNotebook(title: "Models")

        try service.updateNotebookConfigV2(
            nb.id,
            sttModelOverride: .some("stt-profile"),
            llmModelOverride: .some("llm-profile")
        )
        #expect(service.notebook(id: nb.id)?.sttModelOverride == "stt-profile")
        #expect(service.notebook(id: nb.id)?.llmModelOverride == "llm-profile")

        try service.updateNotebookConfigV2(nb.id, sttModelOverride: .some(nil))
        #expect(service.notebook(id: nb.id)?.sttModelOverride == nil)
        #expect(service.notebook(id: nb.id)?.llmModelOverride == "llm-profile")
    }

    @Test("v2 updates remain scoped to the selected notebook")
    func v2UpdatesAreNotebookScoped() throws {
        let modelContainer = try makeConfigTestContainer()
        let service = NoteService(modelContainer: modelContainer)
        let first = try service.createNotebook(title: "First")
        let second = try service.createNotebook(title: "Second")

        try service.updateNotebookConfigV2(
            first.id,
            systemPrompt: "Summarize.",
            outputLanguage: .some("zh-CN"),
            llmModelOverride: .some("llm-profile")
        )

        let fetchedFirst = service.notebook(id: first.id)
        let fetchedSecond = service.notebook(id: second.id)
        #expect(fetchedFirst?.systemPrompt == "Summarize.")
        #expect(fetchedFirst?.outputLanguage == "zh-CN")
        #expect(fetchedFirst?.llmModelOverride == "llm-profile")
        #expect(fetchedSecond?.systemPrompt == "")
        #expect(fetchedSecond?.outputLanguage == nil)
        #expect(fetchedSecond?.llmModelOverride == nil)
    }
}
