import Foundation
import Speech
import Testing
@testable import FonosApp

private enum VoiceWorkflowTestFailure: Error, Equatable {
    case llm
}

private struct CapturedSTTCall: Equatable, Sendable {
    let language: String?
    let vocabulary: [String]
    let promptHint: String
}

private actor VoiceWorkflowSTTDouble: STTProvider {
    enum Behavior: Sendable {
        case succeed(String)
    }

    private let behavior: Behavior
    private(set) var calls: [CapturedSTTCall] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try result()
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String
    ) async throws -> String {
        calls.append(
            CapturedSTTCall(
                language: language,
                vocabulary: vocabulary,
                promptHint: promptHint
            )
        )
        return try result()
    }

    private func result() throws -> String {
        switch behavior {
        case .succeed(let text): return text
        }
    }
}

private actor VoiceWorkflowLLMDouble: VoiceWorkflowLLMProvider {
    enum Behavior: Sendable {
        case succeed(String)
        case fail
    }

    private let behavior: Behavior

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func process(
        text: String,
        configuration: LLMRequestConfiguration
    ) async throws -> String {
        switch behavior {
        case .succeed(let output):
            return output
        case .fail:
            throw VoiceWorkflowTestFailure.llm
        }
    }
}

@MainActor
private func waitForDictationResult(
    _ viewModel: DictationViewModel,
    maxYields: Int = 2_000
) async {
    for _ in 0..<maxYields {
        switch viewModel.recordingState {
        case .result:
            return
        case .error(let message):
            Issue.record("Dictation ended in error: \(message)")
            return
        case .idle, .starting, .recording, .processing:
            await Task.yield()
        }
    }
    Issue.record("Timed out waiting for dictation result")
}

struct VoiceWorkflowDictationIntegrationTests {
    @Test("Dictation adapter clears stale LLM latency on the next raw run")
    @MainActor
    func dictationLatencyDoesNotLeakAcrossRuns() async throws {
        let stt = VoiceWorkflowSTTDouble(.succeed("input"))
        let llm = VoiceWorkflowLLMDouble(.succeed("output"))
        let vm = DictationViewModel(sttProvider: stt, llmProvider: llm)

        vm.selectMode(id: "polish")
        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)
        #expect(vm.llmLatency > 0)

        vm.selectMode(id: "raw")
        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)
        #expect(vm.llmLatency == 0)
    }

    @Test("Dictation publishes a successful canonical workflow outcome")
    @MainActor
    func dictationPresentationLLMSuccess() async {
        let stt = VoiceWorkflowSTTDouble(.succeed("input"))
        let llm = VoiceWorkflowLLMDouble(.succeed("polished"))
        let vm = DictationViewModel(sttProvider: stt, llmProvider: llm)
        vm.selectMode(id: "polish")

        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        #expect(vm.workflowPresentation.phase == .succeeded)
        #expect(vm.workflowPresentation.totalDuration != nil)
        let llmNode = vm.workflowPresentation.nodes.first { $0.typeTag == "llm" }
        if case .succeeded? = llmNode?.state {
            // Expected terminal step state.
        } else {
            Issue.record("Expected a successful canonical LLM node")
        }
    }

    @Test("Imported wf.dictation topology remains authoritative over legacy activeModeID")
    @MainActor
    func importedDictationTopologyExecutes() async {
        let stt = VoiceWorkflowSTTDouble(.succeed("input"))
        let llm = VoiceWorkflowLLMDouble(.succeed("polished"))
        let vm = DictationViewModel(sttProvider: stt, llmProvider: llm)
        var config = WorkflowMigration.migrated(AppConfig())
        config.activeModeID = "polish"
        config.activeVoiceWorkflowID = "wf.dictation"
        config.workflows.removeAll { $0.id == "wf.dictation" }
        config.workflows.append(WorkflowDefinition(
            id: "wf.dictation",
            name: "Dictation · Polish",
            source: "src.mic-hold",
            processors: ["stt.default", "llm.polish"],
            outputs: ["out.insert"],
            builtin: true
        ))
        vm.config = config

        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        #expect(vm.config.activeVoiceWorkflowID == "wf.dictation")
        #expect(vm.workflowPresentation.workflowID == "wf.dictation")
        if case .result(let transcript, let processed) = vm.recordingState {
            #expect(transcript == "input")
            #expect(processed == "polished")
        } else {
            Issue.record("Expected imported dictation result")
        }
    }

    @Test("Dictation publishes a degraded canonical workflow after LLM fallback")
    @MainActor
    func dictationPresentationLLMFallback() async {
        let stt = VoiceWorkflowSTTDouble(.succeed("corrected input"))
        let llm = VoiceWorkflowLLMDouble(.fail)
        let vm = DictationViewModel(sttProvider: stt, llmProvider: llm)
        vm.selectMode(id: "polish")

        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        #expect(vm.workflowPresentation.phase == .degraded)
        let llmNode = vm.workflowPresentation.nodes.first { $0.typeTag == "llm" }
        if case .fallback? = llmNode?.state {
            // Expected terminal step state.
        } else {
            Issue.record("Expected a canonical LLM fallback node")
        }
    }

    @Test("Dictation exposes a missing configured LLM as canonical degradation")
    @MainActor
    func dictationPresentationMissingLLM() async {
        let stt = VoiceWorkflowSTTDouble(.succeed("corrected input"))
        let vm = DictationViewModel(sttProvider: stt)
        vm.selectMode(id: "polish")

        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        #expect(vm.workflowPresentation.phase == .degraded)
        let llm = vm.workflowPresentation.nodes.first { $0.typeTag == "llm" }
        if case .fallback? = llm?.state {
            // Missing default provider follows the widget's use_input policy.
        } else {
            Issue.record("Expected a canonical LLM fallback node")
        }
    }

    @Test("Mode profile overrides win over app defaults and drive provider labels")
    @MainActor
    func modeProfileOverridesDriveProviderLabels() {
        let globalSTT = ModelProfile(
            id: "global-stt",
            name: "Global STT",
            provider: "openai",
            modelID: "whisper-global",
            capabilities: ["stt"]
        )
        let modeSTT = ModelProfile(
            id: "mode-stt",
            name: "Mode STT",
            provider: "openai",
            modelID: "whisper-mode",
            capabilities: ["stt"]
        )
        let globalLLM = ModelProfile(
            id: "global-llm",
            name: "Global LLM",
            provider: "openai",
            modelID: "global-model",
            capabilities: ["llm"]
        )
        let modeLLM = ModelProfile(
            id: "mode-llm",
            name: "Mode LLM",
            provider: "openai",
            modelID: "mode-model",
            capabilities: ["llm"]
        )
        var config = AppConfig()
        config.activeModeID = "polish"
        config.sttProfile = globalSTT.id
        config.llmProfile = globalLLM.id
        config.modelProfiles = [globalSTT, modeSTT, globalLLM, modeLLM]
        let polishIndex = config.modeConfigs.firstIndex(where: { $0.id == "polish" })
        #expect(polishIndex != nil)
        guard let polishIndex else { return }
        config.modeConfigs[polishIndex].sttModelID = modeSTT.id
        config.modeConfigs[polishIndex].llmModelID = modeLLM.id

        WorkflowMigration.migrate(&config)
        config.activeVoiceWorkflowID = "wf.voice.polish"
        let migratedCatalog = config.workflowCatalog
        let migratedWorkflow = migratedCatalog.workflow(id: "wf.voice.polish")
        let migratedProcessors = migratedWorkflow?.processors.compactMap {
            migratedCatalog.widget(id: $0)
        } ?? []
        #expect(migratedProcessors.first(where: { $0.typeTag == "stt" })?
            .props["model_profile"]?.stringValue == modeSTT.id)
        #expect(migratedProcessors.first(where: { $0.typeTag == "llm" })?
            .props["model_profile"]?.stringValue == modeLLM.id)

        let vm = DictationViewModel(
            sttProvider: VoiceWorkflowSTTDouble(.succeed("input"))
        )
        vm.config = config
        #expect(vm.sttProviderName == modeSTT.name)
        #expect(vm.llmProviderName == modeLLM.name)
    }

    @Test("Imported workflow without legacy scope uses global profiles, not stale mode overrides")
    @MainActor
    func importedWorkflowUsesGlobalProfileFallback() {
        let globalSTT = ModelProfile(
            id: "global-stt",
            name: "Global STT",
            provider: "openai",
            modelID: "whisper-global",
            capabilities: ["stt"]
        )
        let modeSTT = ModelProfile(
            id: "mode-stt",
            name: "Mode STT",
            provider: "openai",
            modelID: "whisper-mode",
            capabilities: ["stt"]
        )
        var config = WorkflowMigration.migrated(AppConfig())
        config.modelProfiles = [globalSTT, modeSTT]
        config.sttProfile = globalSTT.id
        config.activeModeID = "polish"
        let polish = config.modeConfigs.firstIndex { $0.id == "polish" }!
        config.modeConfigs[polish].sttModelID = modeSTT.id
        config.workflows.append(WorkflowDefinition(
            id: "wf.mobile",
            name: "Mobile",
            source: "src.mic-hold",
            processors: ["stt.default"],
            outputs: ["out.insert"]
        ))
        config.activeVoiceWorkflowID = "wf.mobile"

        let vm = DictationViewModel(sttProvider: nil)
        vm.config = config

        #expect(vm.sttProviderName == "Global STT")
    }

    @Test("A missing LLM follows canonical use-input degradation semantics")
    @MainActor
    func missingLLMIsDegraded() async throws {
        let stt = VoiceWorkflowSTTDouble(.succeed("corrected input"))
        let vm = DictationViewModel(sttProvider: stt)

        vm.selectMode(id: "polish")
        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        if case .result(let transcript, let processed) = vm.recordingState {
            #expect(transcript == "corrected input")
            #expect(processed == nil)
        } else {
            Issue.record("Expected use-input fallback result")
        }
        #expect(vm.workflowPresentation.phase == .degraded)
        let llmNode = vm.workflowPresentation.nodes.first { $0.widgetID == "llm.polish" }
        if case .fallback? = llmNode?.state {
            // The engine applied the widget's use_input failure policy.
        } else {
            Issue.record("Expected llm.polish to report a fallback")
        }
    }

    @Test("Dictation Flow uses the custom ModeConfig UUID as vocab and prompt scope")
    @MainActor
    func customModeKeepsItsScopeID() async throws {
        let customID = UUID().uuidString
        let customMode = Mode.custom(
            systemPrompt: "Polish this",
            userTemplate: "{text}",
            temperature: 0.2,
            maxTokens: 256
        )
        let modeConfig = ModeConfig(
            id: customID,
            mode: customMode,
            name: "My Mode",
            icon: "sparkles",
            description: "Test mode",
            sttModelID: nil,
            llmModelID: nil,
            sttPrompt: "Names from this project",
            sttTemperature: 0,
            outputLanguage: "auto",
            isBuiltIn: false
        )

        let suiteName = "speech-flow-scope-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let vocabStore = VocabStore(defaults: defaults)
        vocabStore.upsert(
            VocabBook(id: "scoped", name: "Scoped", terms: ["FonosFlow"])
        )
        vocabStore.setMounted(
            ["scoped"],
            forKey: VocabStore.modeMountKey(customID)
        )

        let stt = VoiceWorkflowSTTDouble(.succeed("hello"))
        let vm = DictationViewModel(sttProvider: stt)
        var legacyConfig = AppConfig()
        legacyConfig.modeConfigs.append(modeConfig)
        WorkflowMigration.migrate(&legacyConfig)
        vm.config = legacyConfig
        vm.vocabStore = vocabStore

        vm.selectMode(id: customID)
        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        let call = await stt.calls.first
        #expect(call?.vocabulary == ["FonosFlow"])
        #expect(call?.promptHint == "Names from this project")
    }

    @Test("A disabled book mounted directly on an STT widget stays disabled")
    @MainActor
    func explicitDisabledWorkflowBookIsSkipped() async {
        let suiteName = "speech-flow-disabled-widget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let vocabStore = VocabStore(defaults: defaults)
        var disabled = VocabBook(id: "disabled", name: "Disabled", terms: ["DoNotUse"])
        disabled.enabled = false
        vocabStore.upsert(disabled)

        let sttWidget = WorkflowWidget(
            id: "stt.disabled-book",
            role: .processor,
            typeTag: "stt",
            name: "Disabled book STT",
            props: .object([
                "model_profile": .string(""),
                "language": .string("auto"),
                "vocab_books": .array([.string(disabled.id)])
            ])
        )
        let workflow = WorkflowDefinition(
            id: "wf.disabled-book",
            name: "Disabled book",
            source: "src.mic-hold",
            processors: [sttWidget.id],
            outputs: ["out.insert"]
        )
        let stt = VoiceWorkflowSTTDouble(.succeed("hello"))
        let vm = DictationViewModel(sttProvider: stt)
        var config = WorkflowMigration.migrated(AppConfig())
        config.widgets.append(sttWidget)
        config.workflows.append(workflow)
        config.activeVoiceWorkflowID = workflow.id
        vm.config = config
        vm.vocabStore = vocabStore

        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        let call = await stt.calls.first
        #expect(call?.vocabulary == [])
    }

    @Test("Selecting a custom mode preserves its ModeConfig UUID through the UI adapter")
    @MainActor
    func selectingCustomModePreservesUUID() async {
        let customID = UUID().uuidString
        let customMode = Mode.custom(
            systemPrompt: "Polish this",
            userTemplate: "{text}",
            temperature: 0.2,
            maxTokens: 256
        )
        let modeConfig = ModeConfig(
            id: customID,
            mode: customMode,
            name: "My Mode",
            icon: "sparkles",
            description: "Test mode",
            sttModelID: nil,
            llmModelID: nil,
            sttPrompt: "Project names",
            sttTemperature: 0,
            outputLanguage: "auto",
            isBuiltIn: false
        )
        let stt = VoiceWorkflowSTTDouble(.succeed("hello"))
        let vm = DictationViewModel(sttProvider: stt)
        var legacyConfig = AppConfig()
        legacyConfig.modeConfigs.append(modeConfig)
        WorkflowMigration.migrate(&legacyConfig)
        vm.config = legacyConfig

        vm.selectMode(id: customID)
        #expect(vm.config.activeVoiceWorkflowID == "wf.custom-\(customID)")

        vm.finishRecording(wavData: Data(count: 44))
        await waitForDictationResult(vm)

        #expect(vm.workflowPresentation.workflowID == "wf.custom-\(customID)")
        let call = await stt.calls.first
        #expect(call?.promptHint == "Project names")
    }

    @Test("Selecting a new mode clears the previous result and its Flow metadata")
    @MainActor
    func selectingModeClearsPreviousResult() {
        let vm = DictationViewModel(
            sttProvider: VoiceWorkflowSTTDouble(.succeed("input"))
        )
        vm.recordingState = .result(transcript: "old result", processed: nil)
        vm.sttLatency = 0.5

        vm.selectMode(id: "polish")

        #expect(vm.config.activeVoiceWorkflowID == "wf.voice.polish")
        #expect(vm.recordingState == .idle)
        #expect(vm.workflowPresentation == .idle)
        #expect(vm.sttLatency == 0)
        #expect(vm.llmLatency == 0)
    }
}

private final class HoldingSpeechRecognizer: SpeechRecognizerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func updateLocale(_ locale: Locale) {}

    func requestAuthorization(
        _ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        handler(.authorized)
    }

    func recognize(
        request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SpeechRecognitionOutput?, (any Error)?) -> Void
    ) -> SFSpeechRecognitionTask {
        lock.lock()
        started = true
        lock.unlock()
        return NoopCancellableSpeechTask()
    }
}

private final class NoopCancellableSpeechTask: SFSpeechRecognitionTask, @unchecked Sendable {
    override func cancel() {}
}

struct AppleSTTCancellationTests {
    @Test("AppleSTT resumes promptly when its parent task is cancelled")
    func appleSTTPropagatesCancellation() async throws {
        let recognizer = HoldingSpeechRecognizer()
        let stt = AppleSTT(recognizer: recognizer)
        let task = Task {
            try await stt.transcribe(buffer: Data(count: 44), language: "en-US")
        }

        for _ in 0..<200 where !recognizer.hasStarted {
            await Task.yield()
        }
        #expect(recognizer.hasStarted)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
