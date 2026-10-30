// NoteINV10: Deep link fonos://note and fonos://note?notebook=<id> are handled by FonosApp,
// posting the correct notification so the Notes tab and optional notebook are opened.
//
// Verifier: auto
// Level: unit (notification, buffering, and destination contracts)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV10DeepLinkTests

import Testing
import Foundation
import AVFoundation
import os
@testable import FonosApp

// MARK: - Tests

private func legacyRecordPermission(
    _ permission: AVAudioApplication.recordPermission
) -> AVAudioSession.RecordPermission {
    guard let result = AVAudioSession.RecordPermission(
        rawValue: UInt(permission.rawValue)
    ) else {
        preconditionFailure("Unexpected AVAudioApplication record-permission value")
    }
    return result
}

private final class DeepLinkAudioCapture: AudioCapturing, @unchecked Sendable {
    var currentAudioLevel: Float { 0 }
    var isRecording: Bool { false }
    var isStarting: Bool { false }

    func micPermissionStatus() -> AVAudioSession.RecordPermission {
        legacyRecordPermission(.granted)
    }

    func requestMicPermission() async -> Bool { true }

    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken {
        AudioCaptureStartToken()
    }

    @MainActor
    func stopCapture() -> Data? { nil }
}

private final class PermissionPendingAudioCapture: AudioCapturing, @unchecked Sendable {
    var currentAudioLevel: Float { 0 }
    var isRecording: Bool { false }
    var isStarting: Bool { false }

    func micPermissionStatus() -> AVAudioSession.RecordPermission {
        legacyRecordPermission(.undetermined)
    }

    func requestMicPermission() async -> Bool {
        await Task.yield()
        return false
    }

    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken {
        Issue.record("Capture must not start after permission was denied")
        return AudioCaptureStartToken()
    }

    @MainActor
    func stopCapture() -> Data? { nil }
}

@Suite(.serialized)
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

    @Test("handleDeepLink preserves a malformed notebook id for visible route validation")
    func deepLinkNoteWithMalformedUUID() throws {
        let url = try #require(URL(string: "fonos://note?notebook=not-a-valid-uuid"))
        let routed = try #require(DeepLinkRouter.handle(url))
        guard case .noteRecording(let request) = routed else {
            Issue.record("Expected note-recording route")
            return
        }
        #expect(request.notebookID == "not-a-valid-uuid")
    }

    @Test("cold-start note request remains pending until the root view drains it")
    func coldStartNoteRequestIsBuffered() throws {
        _ = DeepLinkRouter.takePendingRequests()
        let targetID = UUID()
        let routed = DeepLinkRouter.Request.noteRecording(
            NoteRecordingDeepLinkRequest(notebookID: targetID.uuidString)
        )
        DeepLinkRouter.buffer(routed)

        let pending = DeepLinkRouter.takePendingRequests()
        #expect(pending == [routed])
        guard case .noteRecording(let request) = routed else {
            Issue.record("Expected a note recording request")
            return
        }
        #expect(request.notebookID == targetID.uuidString)
    }

    @Test("acknowledging a live request prevents cold-start replay")
    func acknowledgedRequestIsNotReplayed() throws {
        _ = DeepLinkRouter.takePendingRequests()
        let routed = try #require(DeepLinkRouter.handle(
            URL(string: "fonos://record?destination=messages")!
        ))
        DeepLinkRouter.acknowledge(routed.id)
        #expect(DeepLinkRouter.takePendingRequests().isEmpty)
    }

    @Test("dictation destination aliases are explicit and unsupported values throw")
    func oneShotDestinationValidation() throws {
        #expect(try DictationOneShotDestination.resolve("copy") == .clipboard)
        #expect(try DictationOneShotDestination.resolve("sms") == .messages)
        #expect(try DictationOneShotDestination.resolve("mail") == .email)
        #expect(try DictationOneShotDestination.resolve("share_sheet") == .share)
        #expect(throws: DictationOneShotDestinationError.unsupported("printer")) {
            try DictationOneShotDestination.resolve("printer")
        }
    }

    @Test("one-shot route replaces run outputs without changing persisted destination config")
    func oneShotDestinationIsEphemeral() {
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: DeepLinkAudioCapture()
        )
        viewModel.config.autoSendDestination = "messages"
        viewModel.config.destinations.append(
            AnyTextDestination(MessagesDestination())
        )
        let persistedConfig = viewModel.config

        let started = viewModel.startRecording(from: DictationDeepLinkRequest(
            modeID: nil,
            destinationID: "clipboard"
        ))

        #expect(started)
        #expect(viewModel.pendingOneShotDestinationID == nil)
        #expect(viewModel.config == persistedConfig)
        let outputNodes = viewModel.workflowPresentation.nodes.filter { $0.role == .output }
        #expect(outputNodes.count == 1)
        #expect(outputNodes.first?.name == "Clipboard")
        #expect(outputNodes.first?.typeTag == "ios_destination")
    }

    @Test("invalid one-shot destination reports an error and does not start capture")
    func invalidOneShotDestinationIsVisible() {
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: DeepLinkAudioCapture()
        )

        #expect(!viewModel.startRecording(from: DictationDeepLinkRequest(
            modeID: nil,
            destinationID: "printer"
        )))
        guard case .error(let message) = viewModel.recordingState else {
            Issue.record("Expected a visible destination error")
            return
        }
        #expect(message.contains("Unsupported dictation destination"))
        #expect(viewModel.pendingOneShotDestinationID == nil)
    }

    @Test("dictation rejects a deep link while the previous audio is processing")
    func processingRunCannotBeSilentlyReplaced() {
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: DeepLinkAudioCapture()
        )
        viewModel.recordingState = .processing

        #expect(!viewModel.startRecording(from: DictationDeepLinkRequest(
            modeID: "raw",
            destinationID: "clipboard"
        )))
        #expect(viewModel.recordingState == .processing)
        #expect(viewModel.pendingOneShotDestinationID == nil)
    }

    @Test("permission wait freezes the first deep-link destination")
    func permissionWaitRejectsDuplicateDeepLink() async {
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: PermissionPendingAudioCapture()
        )

        #expect(viewModel.startRecording(from: DictationDeepLinkRequest(
            modeID: nil,
            destinationID: "clipboard"
        )))
        #expect(!viewModel.startRecording(from: DictationDeepLinkRequest(
            modeID: nil,
            destinationID: "messages"
        )))
        #expect(viewModel.recordingState == .starting)
        #expect(viewModel.pendingOneShotDestinationID == "clipboard")

        for _ in 0..<10 {
            if case .error = viewModel.recordingState { break }
            await Task.yield()
        }
        guard case .error(let message) = viewModel.recordingState else {
            Issue.record("Expected permission denial to finish the pending request")
            return
        }
        #expect(message.contains("permission"))
        #expect(viewModel.pendingOneShotDestinationID == nil)
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

    @Test("fonos://keyboard-ready routes a buffered Keyboard Ready request")
    func deepLinkKeyboardReady() throws {
        _ = DeepLinkRouter.takePendingRequests()
        let url = try #require(URL(string: "fonos://keyboard-ready"))
        let routed = try #require(DeepLinkRouter.handle(url))
        guard case .keyboardReady = routed else {
            Issue.record("Expected keyboard-ready route")
            return
        }
        // The test host's ContentView may acknowledge the live notification,
        // so only assert the queue never holds anything else.
        let pending = DeepLinkRouter.takePendingRequests()
        #expect(pending.allSatisfy { $0 == routed })
    }

    @Test("handleDeepLink rejects an unrecognised scheme")
    func deepLinkUnrecognisedScheme() throws {
        let url = try #require(URL(string: "https://example.com/note"))
        #expect(DeepLinkRouter.handle(url) == nil)
    }
}
