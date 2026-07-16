// NoteINV13: ModelContainer registers DictationSession, NoteContainer, and NoteEntry.
//
// Verifier: auto
// Levels: static (FonosApp.swift modelContainer includes all three model types — checked at build),
//         unit (ModelContainer can be constructed with all three types without migration error)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV13ContainerTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

// MARK: - Tests

@MainActor
struct NoteINV13ContainerTests {

    @Test("Combined ModelContainer mainContext is non-nil and accepts inserts for all three types")
    func combinedContainerMainContextAcceptsInserts() throws {
        let schema = Schema([
            DictationSession.self,
            NoteContainer.self,
            NoteEntry.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        // Insert one instance of each type
        let session = DictationSession(
            id: UUID(),
            date: .now,
            mode: "raw",
            inputText: "test session",
            outputText: "test session",
            destination: "clipboard",
            latencyMs: 100
        )
        let notebook = NoteContainer(
            id: UUID(),
            title: "Schema Test Notebook",
            containerType: "notebook",
            processingMode: "raw",
            sttModelOverride: nil,
            llmModelOverride: nil,
            customPrompt: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let notebookId = notebook.id
        let entry = NoteEntry(
            id: UUID(),
            createdAt: .now,
            sourceType: "note",
            rawText: "schema test entry",
            processedText: nil,
            containerId: notebookId,
            mode: "raw",
            durationMs: nil,
            language: nil
        )

        context.insert(session)
        context.insert(notebook)
        context.insert(entry)

        // save() must succeed — no migration errors, no constraint violations
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<DictationSession>())
        let notebooks = try context.fetch(FetchDescriptor<NoteContainer>())
        let entries = try context.fetch(FetchDescriptor<NoteEntry>())

        #expect(sessions.count == 1)
        #expect(notebooks.count == 1)
        #expect(entries.count == 1)
    }

    @Test("DictationSession is unaffected when NoteContainer/NoteEntry are inserted into same container")
    func dictationSessionUnaffectedByNoteModels() throws {
        let schema = Schema([
            DictationSession.self,
            NoteContainer.self,
            NoteEntry.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        // Pre-insert a dictation session
        let session = DictationSession(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            mode: "polish",
            inputText: "um yeah so basically",
            outputText: "Essentially,",
            destination: "clipboard",
            latencyMs: 300
        )
        context.insert(session)
        try context.save()

        // Then insert note models
        let notebook = NoteContainer(
            id: UUID(),
            title: "Isolation Test",
            containerType: "notebook",
            processingMode: "raw",
            sttModelOverride: nil,
            llmModelOverride: nil,
            customPrompt: nil,
            createdAt: .now,
            updatedAt: .now
        )
        context.insert(notebook)
        try context.save()

        // Dictation session must still be intact
        let sessions = try context.fetch(FetchDescriptor<DictationSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.inputText == "um yeah so basically")
    }

}
