import Foundation

/// Adds device/config availability checks to the schema/kind validation done
/// by `VoiceWorkflowEngine`. A definition can be portable and structurally
/// valid while still being impossible to start on this phone (for example, an
/// explicitly selected model profile was not imported). All microphone
/// surfaces use this same gate so the picker, importer and runner agree.
struct VoiceWorkflowOperationalValidator: Sendable {
    static let portableOutputTypes: Set<String> = [
        "insert", "return_to_caller", "clipboard"
    ]

    /// The main app can also open a Shortcut, which needs the foreground, so
    /// the keyboard and background runner stay on the portable set.
    static let mainAppOutputTypes = portableOutputTypes.union(["shortcut"])

    /// `validateMicrophone` for recipes run by the main app.
    @discardableResult
    static func validateMainAppMicrophone(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        config: AppConfig
    ) throws -> VoiceWorkflowValidation {
        try validateMicrophone(
            definition: definition,
            catalog: catalog,
            config: config,
            supportedOutputTypes: mainAppOutputTypes,
            allowSurfaceOutputs: true
        )
    }

    @discardableResult
    static func validateMicrophone(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        config: AppConfig,
        supportedOutputTypes: Set<String> = portableOutputTypes,
        allowSurfaceOutputs: Bool = false
    ) throws -> VoiceWorkflowValidation {
        let validation = try VoiceWorkflowEngine().validate(
            definition: definition,
            catalog: catalog,
            allowSurfaceOutputs: allowSurfaceOutputs
        )
        try validateMicrophoneSource(validation, definition: definition)
        try validateOutputs(
            definition: definition,
            catalog: catalog,
            supportedOutputTypes: supportedOutputTypes
        )

        for processorID in definition.processors {
            guard let widget = catalog.widget(id: processorID) else { continue }
            try validateProcessor(widget, config: config)
        }
        return validation
    }

    private static func validateMicrophoneSource(
        _ validation: VoiceWorkflowValidation,
        definition: WorkflowDefinition
    ) throws {
        guard validation.sourceKind == .microphone else {
            throw VoiceWorkflowCompileError.resolutionFailed(
                widgetID: definition.source,
                reason: "this surface requires a microphone source"
            )
        }
    }

    private static func validateOutputs(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        supportedOutputTypes: Set<String>
    ) throws {
        for outputID in definition.outputs {
            guard let output = catalog.widget(id: outputID),
                  supportedOutputTypes.contains(output.typeTag) else {
                throw VoiceWorkflowCompileError.resolutionFailed(
                    widgetID: outputID,
                    reason: "this output is unavailable on the current surface"
                )
            }
        }
    }

    private static func validateProcessor(
        _ widget: WorkflowWidget,
        config: AppConfig
    ) throws {
        let explicitProfileID = widget.props["model_profile"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch widget.typeTag {
        case "stt":
            try validateSTT(widget, explicitProfileID: explicitProfileID, config: config)
        case "llm":
            try validateLLM(widget, explicitProfileID: explicitProfileID, config: config)
        default:
            break
        }
    }

    private static func validateSTT(
        _ widget: WorkflowWidget,
        explicitProfileID: String,
        config: AppConfig
    ) throws {
        let profileID = explicitProfileID.isEmpty
            ? config.sttProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            : explicitProfileID
        // An empty default deliberately means the platform Apple adapter. A
        // non-empty reference must never silently change providers when it
        // becomes dangling.
        guard !profileID.isEmpty else { return }
        guard profileID != ModelProfileReference.appleSpeech else { return }
        guard let profile = config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasSTT
        }) else {
            throw unavailableProfileError(
                widget: widget,
                capability: "STT",
                profileID: profileID,
                isExplicit: !explicitProfileID.isEmpty
            )
        }
        if let reason = unusableReason(profile: profile, capability: "STT") {
            throw VoiceWorkflowCompileError.resolutionFailed(
                widgetID: widget.id,
                reason: reason
            )
        }
    }

    private static func validateLLM(
        _ widget: WorkflowWidget,
        explicitProfileID: String,
        config: AppConfig
    ) throws {
        let profileID = explicitProfileID.isEmpty
            ? config.llmProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            : explicitProfileID
        let policy = widget.props["failure_policy"]?.stringValue
            ?? VoiceWorkflowLLMFailurePolicy.useInput.rawValue
        let mayDegrade = explicitProfileID.isEmpty
            && policy == VoiceWorkflowLLMFailurePolicy.useInput.rawValue

        guard !profileID.isEmpty else {
            if mayDegrade { return }
            throw unavailableProfileError(
                widget: widget,
                capability: "LLM",
                profileID: "default",
                isExplicit: false
            )
        }
        guard let profile = config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasLLM
        }) else {
            if mayDegrade { return }
            throw unavailableProfileError(
                widget: widget,
                capability: "LLM",
                profileID: profileID,
                isExplicit: !explicitProfileID.isEmpty
            )
        }
        if let reason = unusableReason(profile: profile, capability: "LLM") {
            if mayDegrade { return }
            throw VoiceWorkflowCompileError.resolutionFailed(
                widgetID: widget.id,
                reason: reason
            )
        }
    }

    private static func unavailableProfileError(
        widget: WorkflowWidget,
        capability: String,
        profileID: String,
        isExplicit: Bool
    ) -> VoiceWorkflowCompileError {
        let prefix = isExplicit ? "explicit " : ""
        return .resolutionFailed(
            widgetID: widget.id,
            reason: "\(prefix)\(capability) model profile '\(profileID)' is unavailable"
        )
    }

    private static func unusableReason(
        profile: ModelProfile,
        capability: String
    ) -> String? {
        if capability == "STT", profile.provider.lowercased() == "apple" {
            return nil
        }
        if profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(capability) model profile '\(profile.id)' has no model id"
        }
        let baseURL = profile.effectiveBaseURL
        if baseURL.isEmpty {
            return "\(capability) model profile '\(profile.id)' has no endpoint"
        }
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return "\(capability) model profile '\(profile.id)' has an invalid endpoint"
        }
        return nil
    }
}

// MARK: - Production plan factory

/// Resolves the mutable application configuration into one immutable workflow
/// plan. Both the foreground Dictate surface and the keyboard bridge use this
/// factory so provider selection, Keychain lookup and vocabulary snapshotting
/// cannot drift. Output delivery remains a surface-owned adapter.
struct VoiceWorkflowPlanFactory {
    struct Compilation: Sendable {
        let plan: ResolvedVoiceWorkflow
        let hasLLM: Bool
        let hasConfiguredLLM: Bool
        let sttProviderName: String?
        let llmProviderName: String?
    }

    private struct FrozenRuntimes: Sendable {
        var stt: [String: ResolvedVoiceWorkflowSTT] = [:]
        var llm: [String: ResolvedVoiceWorkflowLLM] = [:]
        var vocabulary: [String: VoiceWorkflowVocabulary] = [:]
        var hasLLM = false
        var hasConfiguredLLM = false
        var sttProviderName: String?
        var llmProviderName: String?
    }

    private struct UnavailableLLMProvider: VoiceWorkflowLLMProvider {
        func process(
            text: String,
            configuration: LLMRequestConfiguration
        ) async throws -> String {
            throw LLMError.notConfigured
        }
    }

    private let config: AppConfig
    private let vocabStore: VocabStore
    private let sttProviderOverride: (any STTProvider)?
    private let llmProviderOverride: (any VoiceWorkflowLLMProvider)?
    private let llmOverrideName: String?
    /// Optional surface-owned vocabulary snapshot. Dictate and the keyboard
    /// resolve their mode/workflow mounts below; Notes supplies its notebook
    /// mounts here so every surface still compiles through this one factory.
    private let effectiveVocabularyBooks: [VocabBook]?

    init(
        config: AppConfig,
        vocabStore: VocabStore,
        sttProviderOverride: (any STTProvider)? = nil,
        llmProviderOverride: (any VoiceWorkflowLLMProvider)? = nil,
        llmOverrideName: String? = nil,
        effectiveVocabularyBooks: [VocabBook]? = nil
    ) {
        self.config = config
        self.vocabStore = vocabStore
        self.sttProviderOverride = sttProviderOverride
        self.llmProviderOverride = llmProviderOverride
        self.llmOverrideName = llmOverrideName
        self.effectiveVocabularyBooks = effectiveVocabularyBooks
    }

    /// Every provider and vocab book is resolved before `compile` returns.
    /// Later AppConfig, Keychain or VocabStore changes therefore affect only a
    /// subsequent capture, never an in-flight run.
    func compile(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        legacyScopeID: String?,
        supportedOutputTypes: Set<String> = VoiceWorkflowOperationalValidator.portableOutputTypes,
        allowSurfaceOutputs: Bool = false,
        resolveOutput: @escaping @Sendable (WorkflowWidget) throws -> any VoiceWorkflowOutput
    ) throws -> Compilation {
        try VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: definition,
            catalog: catalog,
            config: config,
            supportedOutputTypes: supportedOutputTypes,
            allowSurfaceOutputs: allowSurfaceOutputs
        )
        let runtimes = freezeRuntimes(
            definition: definition,
            catalog: catalog,
            legacyScopeID: legacyScopeID
        )
        let plan = try VoiceWorkflowEngine().compile(
            definition: definition,
            catalog: catalog,
            resolver: runtimeResolver(
                frozen: runtimes,
                resolveOutput: resolveOutput
            )
        )
        return Compilation(
            plan: plan,
            hasLLM: runtimes.hasLLM,
            hasConfiguredLLM: runtimes.hasConfiguredLLM,
            sttProviderName: runtimes.sttProviderName,
            llmProviderName: runtimes.llmProviderName
        )
    }

    private func freezeRuntimes(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        legacyScopeID: String?
    ) -> FrozenRuntimes {
        var frozen = FrozenRuntimes()
        for processorID in definition.processors {
            guard let widget = catalog.widget(id: processorID) else { continue }
            let explicitProfileID = widget.props["model_profile"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            frozen.vocabulary[widget.id] = vocabularySnapshot(
                workflowID: definition.id,
                legacyScopeID: legacyScopeID,
                widget: widget
            )
            switch widget.typeTag {
            case "stt":
                freezeSTT(widget, explicitProfileID: explicitProfileID, into: &frozen)
            case "llm":
                freezeLLM(widget, explicitProfileID: explicitProfileID, into: &frozen)
            default:
                break
            }
        }
        return frozen
    }

    private func freezeSTT(
        _ widget: WorkflowWidget,
        explicitProfileID: String,
        into frozen: inout FrozenRuntimes
    ) {
        let profileID = explicitProfileID.isEmpty
            ? ModelProfileReference.normalized(config.sttProfile)
            : explicitProfileID
        let provider = sttProviderOverride
            ?? STTResolver.resolve(config: config, profileID: profileID)
        frozen.stt[widget.id] = ResolvedVoiceWorkflowSTT(provider: provider)
        if profileID == ModelProfileReference.appleSpeech {
            frozen.sttProviderName = "Apple Speech"
        } else if let profile = config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasSTT
        }) {
            frozen.sttProviderName = profile.name
        } else {
            frozen.sttProviderName = "Apple Speech"
        }
    }

    private func freezeLLM(
        _ widget: WorkflowWidget,
        explicitProfileID: String,
        into frozen: inout FrozenRuntimes
    ) {
        frozen.hasLLM = true
        let translateTarget = workflowTranslateTarget(for: widget)
        if let llmProviderOverride {
            frozen.llm[widget.id] = ResolvedVoiceWorkflowLLM(
                provider: llmProviderOverride,
                translateTarget: translateTarget
            )
            frozen.hasConfiguredLLM = true
            frozen.llmProviderName = llmOverrideName
            return
        }

        let profileID = explicitProfileID.isEmpty
            ? ModelProfileReference.normalized(config.llmProfile)
            : explicitProfileID
        guard let profile = config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasLLM
        }) else {
            // Keep compilation structural. The widget's failure policy decides
            // whether this missing capability degrades or fails.
            frozen.llm[widget.id] = ResolvedVoiceWorkflowLLM(
                provider: UnavailableLLMProvider(),
                translateTarget: translateTarget
            )
            frozen.llmProviderName = nil
            return
        }

        let key = (try? KeychainStore(service: "com.fonos.models").get(profile.id)) ?? ""
        frozen.llm[widget.id] = ResolvedVoiceWorkflowLLM(
            provider: LLMService(
                apiKey: key,
                modelID: profile.modelID,
                baseURL: profile.effectiveBaseURL,
                provider: profile.provider
            ),
            translateTarget: translateTarget
        )
        frozen.hasConfiguredLLM = true
        frozen.llmProviderName = profile.name
    }

    /// `{target_lang}` is a workflow-template concern. Desktop-compatible
    /// widgets already carry `output_language`; legacy Translate recipes bake
    /// their target into `user_template` during migration.
    private func workflowTranslateTarget(for widget: WorkflowWidget) -> String {
        let outputLanguage = widget.props["output_language"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return outputLanguage.isEmpty || outputLanguage == "auto"
            ? "English"
            : outputLanguage
    }

    private func runtimeResolver(
        frozen: FrozenRuntimes,
        resolveOutput: @escaping @Sendable (WorkflowWidget) throws -> any VoiceWorkflowOutput
    ) -> VoiceWorkflowRuntimeResolver {
        let frozenSTT = frozen.stt
        let frozenLLM = frozen.llm
        let frozenVocab = frozen.vocabulary
        return VoiceWorkflowRuntimeResolver(
            resolveSTT: { widget in
                guard let runtime = frozenSTT[widget.id] else {
                    throw VoiceWorkflowCompileError.resolutionFailed(
                        widgetID: widget.id,
                        reason: "STT runtime was not frozen"
                    )
                }
                return runtime
            },
            resolveLLM: { widget in
                guard let runtime = frozenLLM[widget.id] else {
                    throw VoiceWorkflowCompileError.resolutionFailed(
                        widgetID: widget.id,
                        reason: "LLM runtime was not frozen"
                    )
                }
                return runtime
            },
            resolveVocabulary: { _, widget in
                frozenVocab[widget.id]
                    ?? VoiceWorkflowVocabulary(effectiveBooks: [])
            },
            resolveOutput: resolveOutput
        )
    }

    private func vocabularySnapshot(
        workflowID: String,
        legacyScopeID: String?,
        widget: WorkflowWidget
    ) -> VoiceWorkflowVocabulary {
        var books = effectiveVocabularyBooks ?? vocabStore.effectiveBooks(
            modeID: legacyScopeID ?? workflowID
        )
        for id in widget.props["vocab_books"]?.stringArray ?? [] {
            guard !books.contains(where: { $0.id == id }),
                  let book = vocabStore.book(id: id),
                  book.enabled else { continue }
            books.append(book)
        }
        return VoiceWorkflowVocabulary(effectiveBooks: books)
    }
}
