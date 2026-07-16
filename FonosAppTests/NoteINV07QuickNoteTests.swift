// NoteINV07: Quick Note default notebook — auto-created on first launch, cannot be deleted.
//
// Verifier: auto
// Level: unit (in-memory SwiftData ModelContainer)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV07QuickNoteTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

// MARK: - In-memory container helper

@MainActor
private func makeQuickNoteContainer() throws -> ModelContainer {
    let schema = Schema([NoteContainer.self, NoteEntry.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private enum QuickNoteSaveFailure: Error {
    case injected
}

// MARK: - Tests

@MainActor
struct NoteINV07QuickNoteTests {

    // MARK: - Quick Note creation

    @Test("NoteService.quickNoteNotebook returns a NoteContainer")
    func quickNoteNotebookNotNil() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)

        let quickNote = try service.quickNoteNotebook()
        #expect(NoteService.isQuickNote(quickNote))
    }

    @Test("NoteService.quickNoteNotebook has title 'Quick Note'")
    func quickNoteNotebookTitle() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)

        let quickNote = try service.quickNoteNotebook()
        #expect(quickNote.title == "Quick Note")
    }

    @Test("NoteService.quickNoteNotebook is idempotent — two calls return same notebook")
    func quickNoteNotebookIdempotent() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)

        let first = try service.quickNoteNotebook()
        let second = try service.quickNoteNotebook()
        #expect(first.id == second.id)

        // Only one Quick Note notebook should exist in storage
        let context = modelContainer.mainContext
        let all = try context.fetch(FetchDescriptor<NoteContainer>())
        let quickNoteCount = all.filter(NoteService.isQuickNote).count
        #expect(quickNoteCount == 1)
    }

    @Test("NoteService.quickNoteNotebook persists across service instances sharing the same container")
    func quickNoteNotebookPersistsAcrossInstances() throws {
        let modelContainer = try makeQuickNoteContainer()

        let service1 = NoteService(modelContainer: modelContainer)
        let firstId = try service1.quickNoteNotebook().id

        let service2 = NoteService(modelContainer: modelContainer)
        let secondId = try service2.quickNoteNotebook().id

        #expect(firstId == secondId)
    }

    // MARK: - Quick Note delete protection

    @Test("Deleting Quick Note notebook throws an error")
    func deleteQuickNoteThrows() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)

        let id = try service.quickNoteNotebook().id

        #expect(throws: NoteServiceError.cannotDeleteQuickNote) {
            try service.deleteNotebook(id)
        }
    }

    @Test("Quick Note notebook remains in storage after failed delete attempt")
    func quickNoteRemainsAfterDeleteAttempt() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)

        let id = try service.quickNoteNotebook().id

        try? service.deleteNotebook(id) // ignore error — we're testing side effects

        let context = modelContainer.mainContext
        let all = try context.fetch(FetchDescriptor<NoteContainer>())
        let stillExists = all.contains(where: { $0.id == id })
        #expect(stillExists)
    }

    @Test("Deleting a regular notebook does not throw")
    func deleteRegularNotebookDoesNotThrow() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)

        _ = try service.quickNoteNotebook() // ensure Quick Note exists
        let regularNotebook = try service.createNotebook(title: "Regular Notebook")

        // This must not throw
        #expect(throws: Never.self) {
            try service.deleteNotebook(regularNotebook.id)
        }
    }

    @Test("Quick Note identity survives rename and remains protected")
    func quickNoteIdentityDoesNotDependOnTitle() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)
        let quickNote = try service.quickNoteNotebook()

        try service.renameNotebook(quickNote.id, to: "Inbox")

        let renamed = try #require(service.notebook(id: quickNote.id))
        #expect(renamed.title == "Inbox")
        #expect(NoteService.isQuickNote(renamed))
        #expect(try service.quickNoteNotebook().id == quickNote.id)
        #expect(throws: NoteServiceError.cannotDeleteQuickNote) {
            try service.deleteNotebook(quickNote.id)
        }
    }

    @Test("A regular notebook named Quick Note is not treated as the system notebook")
    func duplicateTitleRemainsRegularAndDeletable() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(modelContainer: modelContainer)
        let system = try service.quickNoteNotebook()
        let duplicate = try service.createNotebook(title: "Quick Note")

        #expect(NoteService.isQuickNote(system))
        #expect(!NoteService.isQuickNote(duplicate))
        try service.deleteNotebook(duplicate.id)
        #expect(service.notebook(id: duplicate.id) == nil)
        #expect(try service.quickNoteNotebook().id == system.id)
    }

    @Test("legacy title-only Quick Note is migrated to the persistent marker")
    func legacyQuickNoteGetsMarker() throws {
        let modelContainer = try makeQuickNoteContainer()
        let context = modelContainer.mainContext
        let legacy = NoteContainer(
            title: "Quick Note",
            containerType: "notebook",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        context.insert(legacy)
        try context.save()

        let service = NoteService(modelContainer: modelContainer)
        let resolved = try service.quickNoteNotebook()
        #expect(resolved.id == legacy.id)
        #expect(NoteService.isQuickNote(resolved))
    }

    @Test("Quick Note creation rolls back when persistence fails")
    func quickNoteCreateFailureRollsBack() throws {
        let modelContainer = try makeQuickNoteContainer()
        let service = NoteService(
            modelContainer: modelContainer,
            saveContext: { _ in throw QuickNoteSaveFailure.injected }
        )

        #expect(throws: NoteServiceError.self) {
            _ = try service.quickNoteNotebook()
        }
        #expect(service.allNotebooks().isEmpty)
    }

    @Test("legacy Quick Note migration rolls back when persistence fails")
    func quickNoteMigrationFailureRollsBack() throws {
        let modelContainer = try makeQuickNoteContainer()
        let context = modelContainer.mainContext
        let legacy = NoteContainer(
            title: "Quick Note",
            containerType: "notebook",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        context.insert(legacy)
        try context.save()
        let service = NoteService(
            modelContainer: modelContainer,
            saveContext: { _ in throw QuickNoteSaveFailure.injected }
        )

        #expect(throws: NoteServiceError.self) {
            _ = try service.quickNoteNotebook()
        }
        #expect(service.notebook(id: legacy.id)?.containerType == "notebook")
    }
}
