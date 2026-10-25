import Foundation
import SwiftUI
import SwiftData
import os.log

extension DictationViewModel {
    var sttProviderName: String {
        if let frozenSTTProviderName { return frozenSTTProviderName }
        let profileID = activeProcessorProfileID(
            typeTag: "stt",
            fallback: fallbackProfileID(for: "stt")
        )
        guard let profile = config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasSTT
        }) else { return "Apple Speech" }
        return profile.name
    }

    /// Human-readable name of the current LLM provider for UI display.
    var llmProviderName: String? {
        if let frozenLLMProviderName { return frozenLLMProviderName }
        guard activeWorkflowUsesLLM else { return nil }
        let profileID = activeProcessorProfileID(
            typeTag: "llm",
            fallback: fallbackProfileID(for: "llm")
        )
        return config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasLLM
        })?.name
    }

    func activeProcessorProfileID(typeTag: String, fallback: String) -> String {
        guard let definition = activeWorkflowDefinition else { return fallback }
        let catalog = config.workflowCatalog
        guard let widget = definition.processors
            .compactMap({ catalog.widget(id: $0) })
            .first(where: { $0.typeTag == typeTag }) else { return fallback }
        let explicit = widget.props["model_profile"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explicit.isEmpty ? fallback : explicit
    }

    func fallbackProfileID(for typeTag: String) -> String {
        switch typeTag {
        case "stt":
            return config.sttProfile
        case "llm":
            return config.llmProfile
        default:
            return ""
        }
    }

    struct MainSurfaceWorkflow {
        let definition: WorkflowDefinition
        let catalog: WorkflowCatalog
        let outputsByWidgetID: [String: any VoiceWorkflowOutput]
        let destinationSummary: String
    }

    struct PreparedMainWorkflow {
        let runID: UUID
        let sourceStartedAt: Date
        /// Persisted/shared identity, before ephemeral iOS output adapters.
        let persistedDefinition: WorkflowDefinition
        let surface: MainSurfaceWorkflow
        let compiled: VoiceWorkflowPlanFactory.Compilation
    }

    /// Resolve every mutable setting before execution. The engine receives
    /// only frozen providers, vocab snapshots and output adapters.
    @MainActor
    func compileMainWorkflow(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        legacyScopeID: String?,
        outputsByWidgetID: [String: any VoiceWorkflowOutput]
    ) throws -> VoiceWorkflowPlanFactory.Compilation {
        let frozenOutputs = outputsByWidgetID
        let compiled = try VoiceWorkflowPlanFactory(
            config: config,
            vocabStore: vocabStore,
            sttProviderOverride: _testSTT,
            llmProviderOverride: _testLLM,
            llmOverrideName: _testLLM == nil ? nil : "Test LLM"
        ).compile(
            definition: definition,
            catalog: catalog,
            legacyScopeID: legacyScopeID,
            supportedOutputTypes: [
                "insert", "return_to_caller", "clipboard", "ios_destination", "shortcut"
            ],
            allowSurfaceOutputs: true,
            resolveOutput: { widget in
                switch widget.typeTag {
                case "insert", "return_to_caller":
                    return ReturnToCallerVoiceWorkflowOutput()
                case "clipboard":
                    return TextDestinationVoiceWorkflowOutput(
                        destination: AnyTextDestination(ClipboardDestination())
                    )
                case "shortcut":
                    return ShortcutVoiceWorkflowOutput(
                        shortcutName: widget.props["shortcut_name"]?.stringValue ?? ""
                    )
                case "ios_destination":
                    guard let output = frozenOutputs[widget.id] else {
                        throw VoiceWorkflowCompileError.resolutionFailed(
                            widgetID: widget.id,
                            reason: "iOS destination was not frozen"
                        )
                    }
                    return output
                default:
                    throw VoiceWorkflowCompileError.unsupportedWidget(
                        widgetID: widget.id,
                        role: widget.role,
                        typeTag: widget.typeTag
                    )
                }
            }
        )
        frozenSTTProviderName = compiled.sttProviderName
        frozenLLMProviderName = compiled.llmProviderName
        return compiled
    }

    /// Build the effective mobile topology. Legacy auto-send is represented as
    /// an ephemeral output widget so it participates in validation, trace,
    /// cancellation and failure semantics without leaking an iOS-only widget
    /// into the shared desktop scenario format.
    func mainSurfaceWorkflow(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        oneShotDestination: DictationOneShotDestination? = nil
    ) -> MainSurfaceWorkflow {
        var effectiveDefinition = definition
        var effectiveCatalog = catalog
        var outputsByWidgetID: [String: any VoiceWorkflowOutput] = [:]

        var deliveredIDs: [String] = []
        for outputID in definition.outputs {
            guard let widget = catalog.widget(id: outputID) else { continue }
            let destinationID: String
            switch widget.typeTag {
            case "clipboard": destinationID = "clipboard"
            case "insert", "return_to_caller": destinationID = "result"
            case "ios_destination":
                destinationID = widget.props["destination_id"]?.stringValue ?? widget.id
            default: destinationID = widget.id
            }
            if !deliveredIDs.contains(destinationID) { deliveredIDs.append(destinationID) }
        }

        // A Shortcut/deep-link destination replaces the persisted surface
        // outputs for this run only. The source/processors and persisted
        // workflow identity remain unchanged, and AppConfig is never mutated.
        if let oneShotDestination {
            let widgetID = "out.ios-one-shot"
            let widget = WorkflowWidget(
                id: widgetID,
                role: .output,
                typeTag: "ios_destination",
                name: oneShotDestination.displayName,
                icon: oneShotDestination.icon,
                props: .object([
                    "destination_id": .string(oneShotDestination.rawValue),
                    "one_shot": .bool(true)
                ])
            )
            if let index = effectiveCatalog.widgets.firstIndex(where: { $0.id == widgetID }) {
                effectiveCatalog.widgets[index] = widget
            } else {
                effectiveCatalog.widgets.append(widget)
            }
            effectiveDefinition.outputs = [widgetID]
            outputsByWidgetID[widgetID] = OneShotDictationVoiceWorkflowOutput(
                destination: oneShotDestination
            )
            return MainSurfaceWorkflow(
                definition: effectiveDefinition,
                catalog: effectiveCatalog,
                outputsByWidgetID: outputsByWidgetID,
                destinationSummary: oneShotDestination.rawValue
            )
        }

        if !config.autoSendDestination.isEmpty,
           !deliveredIDs.contains(config.autoSendDestination),
           let destination = config.destinations.first(where: {
               $0.id == config.autoSendDestination
           }) {
            let widgetID = "out.ios-auto"
            let widget = WorkflowWidget(
                id: widgetID,
                role: .output,
                typeTag: "ios_destination",
                name: "Auto-send · \(destinationDisplayName(destination.id))",
                icon: "arrow.up.forward.app",
                props: .object(["destination_id": .string(destination.id)])
            )
            if let index = effectiveCatalog.widgets.firstIndex(where: { $0.id == widgetID }) {
                effectiveCatalog.widgets[index] = widget
            } else {
                effectiveCatalog.widgets.append(widget)
            }
            effectiveDefinition.outputs.append(widgetID)
            outputsByWidgetID[widgetID] = TextDestinationVoiceWorkflowOutput(
                destination: destination
            )
            deliveredIDs.append(destination.id)
        }

        return MainSurfaceWorkflow(
            definition: effectiveDefinition,
            catalog: effectiveCatalog,
            outputsByWidgetID: outputsByWidgetID,
            destinationSummary: deliveredIDs.joined(separator: ",")
        )
    }

    func destinationDisplayName(_ id: String) -> String {
        switch id {
        case "clipboard": return String(localized: "Clipboard")
        case "messages": return String(localized: "Messages")
        case "url_scheme": return String(localized: "URL Scheme")
        case "result": return String(localized: "Result")
        default: return id
        }
    }

    @MainActor
    func prepareMainWorkflow(
        oneShotDestination: DictationOneShotDestination? = nil
    ) throws -> PreparedMainWorkflow {
        WorkflowMigration.migrate(&config)
        let catalog = config.workflowCatalog
        guard let definition = catalog.workflow(id: config.activeVoiceWorkflowID) else {
            throw VoiceWorkflowCompileError.unknownWidget(
                workflowID: config.activeVoiceWorkflowID,
                widgetID: config.activeVoiceWorkflowID
            )
        }
        guard catalog.widget(id: definition.source)?.typeTag == "microphone" else {
            throw VoiceWorkflowCompileError.unsupportedWidget(
                widgetID: definition.source,
                role: .source,
                typeTag: catalog.widget(id: definition.source)?.typeTag ?? "missing"
            )
        }

        let legacyScopeID = legacyScopeID(for: definition)
        let surface = mainSurfaceWorkflow(
            definition: definition,
            catalog: catalog,
            oneShotDestination: oneShotDestination
        )
        let compiled = try compileMainWorkflow(
            definition: surface.definition,
            catalog: surface.catalog,
            legacyScopeID: legacyScopeID,
            outputsByWidgetID: surface.outputsByWidgetID
        )
        return PreparedMainWorkflow(
            runID: UUID(),
            sourceStartedAt: Date(),
            persistedDefinition: definition,
            surface: surface,
            compiled: compiled
        )
    }

    /// Freezes and consumes the one-shot route even if preflight fails, so an
    /// invalid recipe cannot accidentally apply a Shortcut destination to a
    /// later manual dictation.
    @MainActor
    func prepareNextMainWorkflow() throws -> PreparedMainWorkflow {
        let oneShotDestination = pendingOneShotDestination
        pendingOneShotDestination = nil
        return try prepareMainWorkflow(oneShotDestination: oneShotDestination)
    }

    /// Poll audio level at 10fps — fast enough for waveform, slow enough to not starve touch events.
    func startLevelPolling() {
        levelPollTimer?.invalidate()
        levelPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level = self.audioCapture.currentAudioLevel
            // Only update if level actually changed (avoids unnecessary SwiftUI re-renders)
            if abs(self.audioLevel - level) > 0.01 {
                self.audioLevel = level
            }
        }
    }

    func stopLevelPolling() {
        levelPollTimer?.invalidate()
        levelPollTimer = nil
        audioLevel = 0
    }

    // MARK: - Hold-to-record gesture logic

    /// Decides how a hold-gesture change maps onto recorder actions.
    /// Inert unless the configured record mode is `.hold`.
    static func holdGestureAction(pressing: Bool,
                                  state: RecordingState,
                                  recordMode: RecordMode) -> RecordGestureAction {
        guard recordMode == .hold else { return .none }
        switch (pressing, state) {
        case (true, .idle), (true, .result), (true, .error):
            return .start
        case (false, .starting), (false, .recording):
            return .stop
        default:
            return .none
        }
    }

    // MARK: - Recording Control

}
