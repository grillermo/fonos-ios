import UIKit
@preconcurrency import AVFoundation
import SwiftData
import os.log

extension BackgroundRecordingService {
    func transcribeAndProcess(
        wavData: Data,
        sessionID: String?,
        bgTaskID: UIBackgroundTaskIdentifier,
        prepared: PreparedKeyboardWorkflow
    ) {
        guard sessionState.activeSessionID == sessionID,
              processingSessionID == sessionID,
              processingBackgroundTaskID == bgTaskID else {
            endBackgroundTask(bgTaskID)
            return
        }
        backgroundRecordingLog.info("🎙 BG: recipe=\(prepared.definition.id, privacy: .public), components=\(prepared.plan.validation.steps.count)")

        let processingRunID = UUID()
        self.processingRunID = processingRunID
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await VoiceWorkflowEngine().run(
                    VoiceWorkflowRunInput(
                        audioData: wavData,
                        source: prepared.plan.validation.sourceKind,
                        sourceAcquisitionDuration: Date().timeIntervalSince(
                            prepared.sourceStartedAt
                        )
                    ),
                    using: prepared.plan,
                    recorder: { [weak self] processed in
                        await self?.persistKeyboardSession(
                            processed: processed,
                            definition: prepared.definition,
                            destinationSummary: prepared.destinationSummary
                        )
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.processingRunID == processingRunID else { return }
                    // Publish only after every recipe output succeeds. Session
                    // identity makes stale completions a no-op.
                    if self.writeFinal(
                        result.finalText,
                        sessionID: sessionID,
                        delivery: prepared.delivery
                    ) {
                        backgroundRecordingLog.info("🎙 BG: ✅ Done: \"\(result.finalText.prefix(50))...\", session=\((sessionID ?? "-").prefix(8))")
                    }
                    self.finishProcessingTask(
                        runID: processingRunID,
                        backgroundTaskID: bgTaskID
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishProcessingTask(
                        runID: processingRunID,
                        backgroundTaskID: bgTaskID
                    )
                }
            } catch {
                backgroundRecordingLog.error("🎙 BG: ❌ recipe failed: \(error.localizedDescription)")
                await MainActor.run {
                    _ = self.writeError(
                        "Recipe: \(error.localizedDescription)",
                        sessionID: sessionID
                    )
                    self.finishProcessingTask(
                        runID: processingRunID,
                        backgroundTaskID: bgTaskID
                    )
                }
            }
        }
    }

    func finishProcessingTask(
        runID: UUID,
        backgroundTaskID: UIBackgroundTaskIdentifier
    ) {
        guard processingRunID == runID else { return }
        processingRunID = nil
        processingTask = nil
        processingSessionID = nil
        endBackgroundTask(backgroundTaskID)
        finishExpiredReadySessionIfPossible()
    }

    func cancelProcessingTask() {
        let backgroundTaskID = processingBackgroundTaskID
        processingTask?.cancel()
        processingTask = nil
        processingRunID = nil
        processingSessionID = nil
        endBackgroundTask(backgroundTaskID)
    }

    func expireProcessing(
        sessionID: String?,
        backgroundTaskID: UIBackgroundTaskIdentifier
    ) {
        guard processingSessionID == sessionID,
              processingBackgroundTaskID == backgroundTaskID else {
            backgroundRecordingLog.info("🎙 BG: ignored stale expiry for session \((sessionID ?? "-").prefix(8))")
            return
        }
        processingTask?.cancel()
        processingTask = nil
        processingRunID = nil
        processingSessionID = nil
        _ = writeError("Processing expired. Try again.", sessionID: sessionID)
        endBackgroundTask(backgroundTaskID)
        finishExpiredReadySessionIfPossible()
    }

    func endBackgroundTask(_ bgTaskID: UIBackgroundTaskIdentifier) {
        guard bgTaskID != .invalid,
              processingBackgroundTaskID == bgTaskID else { return }
        runOnMainSync {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }
        processingBackgroundTaskID = .invalid
        if processingTask == nil, processingRunID == nil {
            processingSessionID = nil
        }
    }

    @MainActor
    func persistKeyboardSession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition,
        destinationSummary: String
    ) {
        guard let modelContext else { return }
        let legacyModeID = WorkflowMigration.legacyModeID(forWorkflowID: definition.id)
        let session = DictationSession(
            date: Date(),
            workflowID: definition.id,
            workflowName: definition.name,
            mode: legacyModeID ?? definition.id,
            inputText: processed.rawText,
            outputText: processed.finalText,
            destination: destinationSummary,
            latencyMs: processed.timings.total * 1_000
        )
        modelContext.insert(session)
        do {
            try modelContext.save()
        } catch {
            backgroundRecordingLog.error("🎙 BG: history save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Provider Resolution

    func readAppConfig() -> AppConfig {
        AppConfigStorage.load() ?? WorkflowMigration.migrated(AppConfig())
    }

    func resolveWorkflowID(config: AppConfig) -> String {
        let isRunnable: (String) -> Bool = { id in
            guard let definition = config.workflowCatalog.workflow(id: id) else { return false }
            return (try? VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: config.workflowCatalog,
                config: config
            )) != nil
        }
        if let workflowID = AppConfigStorage.keyboardWorkflowID(),
           isRunnable(workflowID) {
            return workflowID
        }
        if let legacyModeID = AppConfigStorage.keyboardModeID() {
            let workflowID = WorkflowMigration.workflowID(forLegacyModeID: legacyModeID)
            if isRunnable(workflowID) {
                return workflowID
            }
        }
        if isRunnable(config.activeVoiceWorkflowID) {
            return config.activeVoiceWorkflowID
        }
        return isRunnable("wf.dictation") ? "wf.dictation" : ""
    }

    func compileKeyboardWorkflow(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        config: AppConfig
    ) throws -> ResolvedVoiceWorkflow {
        let legacyScopeID = WorkflowMigration.legacyModeID(forWorkflowID: definition.id)
        let compilation = try VoiceWorkflowPlanFactory(
            config: config,
            vocabStore: VocabStore()
        ).compile(
            definition: definition,
            catalog: catalog,
            legacyScopeID: legacyScopeID,
            resolveOutput: { widget in
                switch widget.typeTag {
                case "insert", "return_to_caller": return ReturnToCallerVoiceWorkflowOutput()
                case "clipboard": return BackgroundClipboardVoiceWorkflowOutput()
                default:
                    throw VoiceWorkflowCompileError.unsupportedWidget(
                        widgetID: widget.id,
                        role: widget.role,
                        typeTag: widget.typeTag
                    )
                }
            }
        )
        return compilation.plan
    }

    // MARK: - File-based IPC

    func writeFile(_ name: String, _ content: String) {
        guard let url = containerURL(name) else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    func readFile(_ name: String) -> String? {
        guard let url = containerURL(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func deleteFile(_ name: String) {
        guard let url = containerURL(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func resetKeyboardIPCForNewAppInstance() {
        resetKeyboardIPCForRecorderRestart()
        deleteFile(KeyboardIPC.FileName.cancelSessionID)
        backgroundRecordingLog.info("🎙 BG: reset keyboard IPC, appInstance=\(self.appInstanceID.prefix(8))")
    }

    func resetKeyboardIPCForRecorderRestart() {
        writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
        clearKeyboardIPCResultFiles()
    }

    func clearKeyboardIPCResultFiles() {
        deleteFile(KeyboardIPC.FileName.startAckSessionID)
        deleteFile(KeyboardIPC.FileName.resultSessionID)
        deleteFile(KeyboardIPC.FileName.delivery)
        deleteFile(KeyboardIPC.FileName.status)
        deleteFile(KeyboardIPC.FileName.partial)
        deleteFile(KeyboardIPC.FileName.final)
        deleteFile(KeyboardIPC.FileName.error)
    }

    func writeStatus(_ status: String) {
        writeFile(KeyboardIPC.FileName.status, status)
        backgroundRecordingLog.info("🎙 BG: status → \(status)")
    }

    @discardableResult
    func writeFinal(
        _ text: String,
        sessionID: String?,
        delivery: KeyboardIPC.Delivery = .insert
    ) -> Bool {
        guard sessionState.activeSessionID == sessionID else {
            backgroundRecordingLog.info("🎙 BG: ignored stale final for session \((sessionID ?? "-").prefix(8))")
            return false
        }
        writeFile(KeyboardIPC.FileName.final, text)
        writeFile(KeyboardIPC.FileName.delivery, delivery.rawValue)
        if let sessionID {
            writeFile(KeyboardIPC.FileName.resultSessionID, sessionID)
        }
        writeFile(KeyboardIPC.FileName.status, "done")
        backgroundRecordingLog.info("🎙 BG: wrote result (\(text.count) chars)")
        postDarwin(KeyboardIPC.NotificationName.result)
        sessionState.clearIfActive(sessionID: sessionID)
        return true
    }

    @discardableResult
    func writeError(_ msg: String, sessionID: String?) -> Bool {
        guard sessionState.activeSessionID == sessionID else {
            backgroundRecordingLog.info("🎙 BG: ignored stale error for session \((sessionID ?? "-").prefix(8))")
            return false
        }
        writeFile(KeyboardIPC.FileName.error, msg)
        if let sessionID {
            writeFile(KeyboardIPC.FileName.resultSessionID, sessionID)
        }
        writeFile(KeyboardIPC.FileName.status, "error")
        backgroundRecordingLog.info("🎙 BG: wrote error: \(msg)")
        postDarwin(KeyboardIPC.NotificationName.result)
        sessionState.clearIfActive(sessionID: sessionID)
        return true
    }

    func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    func containerURL(_ filename: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(filename)
    }

    func runOnMainSync(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}
