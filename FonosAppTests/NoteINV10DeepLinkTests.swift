// NoteINV10: Deep link fonos://note and fonos://note?notebook=<id> are handled by FonosApp,
// posting the correct notification so the Notes tab and optional notebook are opened.
//
// Verifier: auto
// Level: unit (notification observation, no simulator needed)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV10DeepLinkTests
//
// TDD status: FAILING until deep link handling for fonos://note is added to FonosApp/ContentView.

import Testing
import Foundation
import os
@testable import FonosApp

// MARK: - Tests

@MainActor
struct NoteINV10DeepLinkTests {

    // MARK: - fonos://note base URL

    @Test("handleDeepLink with fonos://note posts a notification")
    func deepLinkNotePostsNotification() async throws {
        await confirmation("Expected .fonosOpenNotes notification to be posted") { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: .fonosOpenNotes,
                object: nil,
                queue: .main
            ) { _ in
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            let url = URL(string: "fonos://note")!
            DeepLinkRouter.handle(url)
        }
    }

    @Test("handleDeepLink with fonos://note posts notification with no notebookId userInfo")
    func deepLinkNoteNoNotebookId() async throws {
        let receivedNotebookID = OSAllocatedUnfairLock<String?>(initialState: nil)
        await confirmation("Expected .fonosOpenNotes notification to be posted") { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: .fonosOpenNotes,
                object: nil,
                queue: .main
            ) { notification in
                let notebookID = notification.userInfo?["notebookId"] as? String
                receivedNotebookID.withLock { $0 = notebookID }
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            let url = URL(string: "fonos://note")!
            DeepLinkRouter.handle(url)
        }

        // No notebookId query parameter → userInfo should not contain one
        #expect(receivedNotebookID.withLock { $0 } == nil)
    }

    // MARK: - fonos://note?notebook=<id>

    @Test("handleDeepLink with fonos://note?notebook=<uuid> posts notification with correct notebookId")
    func deepLinkNoteWithNotebookId() async throws {
        let targetId = UUID()
        let receivedNotebookID = OSAllocatedUnfairLock<UUID?>(initialState: nil)
        await confirmation("Expected .fonosOpenNotes notification to be posted") { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: .fonosOpenNotes,
                object: nil,
                queue: .main
            ) { notification in
                let notebookID = (notification.userInfo?["notebookId"] as? String)
                    .flatMap(UUID.init(uuidString:))
                receivedNotebookID.withLock { $0 = notebookID }
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            let url = URL(string: "fonos://note?notebook=\(targetId.uuidString)")!
            DeepLinkRouter.handle(url)
        }

        #expect(receivedNotebookID.withLock { $0 } == targetId)
    }

    @Test("handleDeepLink with malformed UUID in notebook param does not crash")
    func deepLinkNoteWithMalformedUUID() throws {
        let url = URL(string: "fonos://note?notebook=not-a-valid-uuid")!
        // Must not throw or crash
        DeepLinkRouter.handle(url)
        #expect(Bool(true)) // sentinel — reaching here means no crash
    }

    // MARK: - Unrelated URL is not handled as a note deep link

    @Test("handleDeepLink with fonos://record does not post .fonosOpenNotes notification")
    func deepLinkRecordDoesNotPostNotesNotification() async throws {
        await confirmation(
            "fonos://record must not trigger the Notes deep link handler",
            expectedCount: 0
        ) { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: .fonosOpenNotes,
                object: nil,
                queue: .main
            ) { _ in
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            let url = URL(string: "fonos://record")!
            DeepLinkRouter.handle(url)
        }
    }

    @Test("handleDeepLink with unrecognised scheme does not crash")
    func deepLinkUnrecognisedScheme() throws {
        let url = URL(string: "https://example.com/note")!
        DeepLinkRouter.handle(url)
        #expect(Bool(true))
    }
}

// MARK: - Notification name extension

private extension Notification.Name {
    // TODO: Move this extension to the production code (e.g. Notifications.swift)
    // and import it here via @testable import FonosApp.
    static let fonosOpenNotes = Notification.Name("fonos.openNotes")
}
