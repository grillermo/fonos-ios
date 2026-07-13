import Foundation

// MARK: - Validation and compilation

extension VoiceWorkflowEngine {
    /// Validate only the iOS voice subset of the shared desktop schema.
    /// Unsupported desktop widgets remain round-trippable in AppConfig, but
    /// cannot accidentally execute on iOS.
    func validate(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        allowSurfaceOutputs: Bool = false
    ) throws -> VoiceWorkflowValidation {
        let source = try validatedSource(definition: definition, catalog: catalog)
        var steps: [VoiceWorkflowStep] = [
            VoiceWorkflowStep(
                index: 0,
                widgetID: source.widget.id,
                role: .source,
                typeTag: source.widget.typeTag
            )
        ]
        let finalKind = try validateProcessors(
            definition: definition,
            catalog: catalog,
            steps: &steps
        )
        try validateOutputs(
            definition: definition,
            catalog: catalog,
            allowSurfaceOutputs: allowSurfaceOutputs,
            finalKind: finalKind,
            steps: &steps
        )

        return VoiceWorkflowValidation(
            workflowID: definition.id,
            sourceKind: source.kind,
            steps: steps,
            finalKind: finalKind
        )
    }

    /// Compile a definition into a provider- and configuration-frozen plan.
    func compile(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        resolver: VoiceWorkflowRuntimeResolver
    ) throws -> ResolvedVoiceWorkflow {
        let validation = try validate(
            definition: definition,
            catalog: catalog,
            allowSurfaceOutputs: true
        )
        let source = try resolvedSource(
            definition: definition,
            catalog: catalog,
            validation: validation
        )
        let processors = try resolvedProcessors(
            definition: definition,
            catalog: catalog,
            validation: validation,
            resolver: resolver
        )
        let outputs = try resolvedOutputs(
            definition: definition,
            catalog: catalog,
            validation: validation,
            resolver: resolver
        )

        return ResolvedVoiceWorkflow(
            definition: definition,
            validation: validation,
            source: source,
            processors: processors,
            outputs: outputs
        )
    }

    // MARK: Validation helpers

    private func validatedSource(
        definition: WorkflowDefinition, catalog: WorkflowCatalog
    ) throws -> (widget: WorkflowWidget, kind: VoiceWorkflowSourceKind) {
        let widget = try referencedWidget(
            id: definition.source,
            workflowID: definition.id,
            catalog: catalog
        )
        guard widget.role == .source else {
            throw VoiceWorkflowCompileError.roleMismatch(
                widgetID: widget.id,
                expected: .source,
                actual: widget.role
            )
        }
        switch widget.typeTag {
        case "microphone":
            try validateMicrophoneSourceProperties(widget)
            return (widget, .microphone)
        case "provided_audio":
            return (widget, .providedAudio)
        default:
            throw VoiceWorkflowCompileError.unsupportedWidget(
                widgetID: widget.id,
                role: .source,
                typeTag: widget.typeTag
            )
        }
    }
    private func validateMicrophoneSourceProperties(_ widget: WorkflowWidget) throws {
        guard widget.props == .null || widget.props.objectValue != nil else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "props",
                reason: "expected an object or null"
            )
        }
        if let capture = widget.props["capture"] {
            guard let value = capture.stringValue,
                  value == "hold" || value == "toggle" else {
                throw VoiceWorkflowCompileError.invalidProperty(
                    widgetID: widget.id,
                    key: "capture",
                    reason: "expected hold or toggle"
                )
            }
        }
    }
    private func validateProcessors(
        definition: WorkflowDefinition, catalog: WorkflowCatalog,
        steps: inout [VoiceWorkflowStep]
    ) throws -> WorkflowDataKind {
        var kind: WorkflowDataKind = .audio
        for processorID in definition.processors {
            let widget = try referencedWidget(
                id: processorID,
                workflowID: definition.id,
                catalog: catalog
            )
            kind = try validatedProcessorOutputKind(widget, inputKind: kind)
            steps.append(VoiceWorkflowStep(
                index: steps.count,
                widgetID: widget.id,
                role: .processor,
                typeTag: widget.typeTag
            ))
        }
        return kind
    }
    private func validatedProcessorOutputKind(
        _ widget: WorkflowWidget, inputKind: WorkflowDataKind
    ) throws -> WorkflowDataKind {
        guard widget.role == .processor else {
            throw VoiceWorkflowCompileError.roleMismatch(
                widgetID: widget.id,
                expected: .processor,
                actual: widget.role
            )
        }
        let transition = try processorDataTransition(widget)
        guard transition.accepted == inputKind else {
            throw VoiceWorkflowCompileError.kindMismatch(
                widgetID: widget.id,
                expected: transition.accepted,
                actual: inputKind
            )
        }
        return transition.produced
    }
    private func processorDataTransition(
        _ widget: WorkflowWidget
    ) throws -> (accepted: WorkflowDataKind, produced: WorkflowDataKind) {
        switch widget.typeTag {
        case "stt":
            try validateSTTProcessorProperties(widget)
            return (.audio, .text)
        case "llm":
            try validateLLMProcessorProperties(widget)
            return (.text, .text)
        default:
            throw VoiceWorkflowCompileError.unsupportedWidget(
                widgetID: widget.id,
                role: .processor,
                typeTag: widget.typeTag
            )
        }
    }
    private func validateSTTProcessorProperties(_ widget: WorkflowWidget) throws {
        try validateCommonProcessorProperties(widget)
        _ = try stringProperty(widget, key: "language", default: "auto")
        _ = try stringProperty(widget, key: "stt_prompt", default: "")
        _ = try numberProperty(widget, key: "temperature", default: 0, range: 0...1)
    }
    private func validateLLMProcessorProperties(_ widget: WorkflowWidget) throws {
        try validateCommonProcessorProperties(widget)
        _ = try requestConfiguration(
            widget: widget,
            translateTarget: "English",
            glossary: nil
        )
        _ = try llmFailurePolicy(widget)
    }
    private func validateOutputs(
        definition: WorkflowDefinition, catalog: WorkflowCatalog,
        allowSurfaceOutputs: Bool, finalKind: WorkflowDataKind,
        steps: inout [VoiceWorkflowStep]
    ) throws {
        guard !definition.outputs.isEmpty else {
            throw VoiceWorkflowCompileError.noOutputs(workflowID: definition.id)
        }
        guard finalKind == .text else {
            throw VoiceWorkflowCompileError.finalKindMustBeText(actual: finalKind)
        }
        for outputID in definition.outputs {
            let widget = try referencedWidget(
                id: outputID,
                workflowID: definition.id,
                catalog: catalog
            )
            try validateOutput(widget, allowSurfaceOutputs: allowSurfaceOutputs)
            steps.append(VoiceWorkflowStep(
                index: steps.count,
                widgetID: widget.id,
                role: .output,
                typeTag: widget.typeTag
            ))
        }
    }
    private func validateOutput(
        _ widget: WorkflowWidget, allowSurfaceOutputs: Bool
    ) throws {
        guard widget.role == .output else {
            throw VoiceWorkflowCompileError.roleMismatch(
                widgetID: widget.id,
                expected: .output,
                actual: widget.role
            )
        }
        let supportedTypes = allowSurfaceOutputs
            ? ["insert", "return_to_caller", "clipboard", "ios_destination"]
            : ["insert", "return_to_caller", "clipboard"]
        guard supportedTypes.contains(widget.typeTag) else {
            throw VoiceWorkflowCompileError.unsupportedWidget(
                widgetID: widget.id,
                role: .output,
                typeTag: widget.typeTag
            )
        }
        guard widget.props == .null || widget.props.objectValue != nil else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "props",
                reason: "expected an object or null"
            )
        }
        if widget.typeTag == "insert" {
            try validateInsertOutputProperties(widget)
        }
        if widget.typeTag == "ios_destination" {
            try validateIOSDestinationProperties(widget)
        }
    }
    private func validateInsertOutputProperties(_ widget: WorkflowWidget) throws {
        if let strategy = widget.props["strategy"] {
            guard strategy.stringValue != nil else {
                throw VoiceWorkflowCompileError.invalidProperty(
                    widgetID: widget.id,
                    key: "strategy",
                    reason: "expected a string"
                )
            }
        }
        if let pressEnter = widget.props["press_enter"] {
            guard pressEnter.boolValue != nil else {
                throw VoiceWorkflowCompileError.invalidProperty(
                    widgetID: widget.id,
                    key: "press_enter",
                    reason: "expected a boolean"
                )
            }
        }
    }
    private func validateIOSDestinationProperties(_ widget: WorkflowWidget) throws {
        let destinationID = try stringProperty(widget, key: "destination_id", default: "")
        guard !destinationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "destination_id",
                reason: "expected a non-empty string"
            )
        }
    }

    // MARK: Resolution helpers

    private func resolvedSource(
        definition: WorkflowDefinition, catalog: WorkflowCatalog,
        validation: VoiceWorkflowValidation
    ) throws -> ResolvedVoiceWorkflow.Source {
        let widget = try referencedWidget(
            id: definition.source,
            workflowID: definition.id,
            catalog: catalog
        )
        return ResolvedVoiceWorkflow.Source(
            widget: widget,
            kind: validation.sourceKind,
            step: validation.steps[0]
        )
    }
    private func resolvedProcessors(
        definition: WorkflowDefinition, catalog: WorkflowCatalog,
        validation: VoiceWorkflowValidation, resolver: VoiceWorkflowRuntimeResolver
    ) throws -> [ResolvedVoiceWorkflow.Processor] {
        try definition.processors.enumerated().map { offset, processorID in
            let widget = try referencedWidget(
                id: processorID,
                workflowID: definition.id,
                catalog: catalog
            )
            return try resolvedProcessor(
                widget: widget,
                step: validation.steps[1 + offset],
                workflowID: definition.id,
                resolver: resolver
            )
        }
    }
    private func resolvedProcessor(
        widget: WorkflowWidget, step: VoiceWorkflowStep,
        workflowID: String, resolver: VoiceWorkflowRuntimeResolver
    ) throws -> ResolvedVoiceWorkflow.Processor {
        switch widget.typeTag {
        case "stt":
            return try resolvedSTTProcessor(
                widget: widget,
                step: step,
                workflowID: workflowID,
                resolver: resolver
            )
        case "llm":
            return try resolvedLLMProcessor(
                widget: widget,
                step: step,
                workflowID: workflowID,
                resolver: resolver
            )
        default:
            preconditionFailure("validate accepted an unsupported processor")
        }
    }

    private func resolvedSTTProcessor(
        widget: WorkflowWidget, step: VoiceWorkflowStep,
        workflowID: String, resolver: VoiceWorkflowRuntimeResolver
    ) throws -> ResolvedVoiceWorkflow.Processor {
        try validateCommonProcessorProperties(widget)
        let runtime: ResolvedVoiceWorkflowSTT = try resolve(
            widget: widget,
            operation: { try resolver.resolveSTT(widget) }
        )
        let vocabulary: VoiceWorkflowVocabulary = try resolve(
            widget: widget,
            operation: { try resolver.resolveVocabulary(workflowID, widget) }
        )
        let language = try stringProperty(widget, key: "language", default: "auto")
        let temperature = try numberProperty(
            widget,
            key: "temperature",
            default: 0,
            range: 0...1
        )
        let prompt = try stringProperty(widget, key: "stt_prompt", default: "")
        return .stt(.init(
            widget: widget,
            step: step,
            provider: runtime.provider,
            language: STTLanguageCode.normalized(language),
            promptHint: prompt,
            temperature: temperature,
            vocabulary: vocabulary
        ))
    }

    private func resolvedLLMProcessor(
        widget: WorkflowWidget, step: VoiceWorkflowStep,
        workflowID: String, resolver: VoiceWorkflowRuntimeResolver
    ) throws -> ResolvedVoiceWorkflow.Processor {
        try validateCommonProcessorProperties(widget)
        let runtime: ResolvedVoiceWorkflowLLM = try resolve(
            widget: widget,
            operation: { try resolver.resolveLLM(widget) }
        )
        let vocabulary: VoiceWorkflowVocabulary = try resolve(
            widget: widget,
            operation: { try resolver.resolveVocabulary(workflowID, widget) }
        )
        let request = try requestConfiguration(
            widget: widget,
            translateTarget: runtime.translateTarget,
            glossary: vocabulary.glossary
        )
        return .llm(.init(
            widget: widget,
            step: step,
            provider: runtime.provider,
            request: request,
            failurePolicy: try llmFailurePolicy(widget)
        ))
    }

    private func resolvedOutputs(
        definition: WorkflowDefinition, catalog: WorkflowCatalog,
        validation: VoiceWorkflowValidation, resolver: VoiceWorkflowRuntimeResolver
    ) throws -> [ResolvedVoiceWorkflow.Output] {
        let outputStart = 1 + definition.processors.count
        return try definition.outputs.enumerated().map { offset, outputID in
            let widget = try referencedWidget(
                id: outputID,
                workflowID: definition.id,
                catalog: catalog
            )
            let destination: any VoiceWorkflowOutput = try resolve(
                widget: widget,
                operation: { try resolver.resolveOutput(widget) }
            )
            return .init(
                widget: widget,
                step: validation.steps[outputStart + offset],
                destination: destination
            )
        }
    }

    private func llmFailurePolicy(_ widget: WorkflowWidget) throws -> VoiceWorkflowLLMFailurePolicy {
        let value = try stringProperty(
            widget,
            key: "failure_policy",
            default: VoiceWorkflowLLMFailurePolicy.useInput.rawValue
        )
        guard let policy = VoiceWorkflowLLMFailurePolicy(rawValue: value) else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "failure_policy",
                reason: "expected use_input or fail_run"
            )
        }
        return policy
    }

    // MARK: Compile helpers

    private func referencedWidget(
        id: String, workflowID: String, catalog: WorkflowCatalog
    ) throws -> WorkflowWidget {
        let matches = catalog.widgets.filter { $0.id == id }
        guard !matches.isEmpty else {
            throw VoiceWorkflowCompileError.unknownWidget(
                workflowID: workflowID,
                widgetID: id
            )
        }
        guard matches.count == 1, let widget = matches.first else {
            throw VoiceWorkflowCompileError.ambiguousWidgetID(widgetID: id)
        }
        return widget
    }

    private func validateCommonProcessorProperties(_ widget: WorkflowWidget) throws {
        guard widget.props.objectValue != nil else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "props",
                reason: "expected an object"
            )
        }
        if let profile = widget.props["model_profile"], profile.stringValue == nil {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "model_profile",
                reason: "expected a string"
            )
        }
        if let books = widget.props["vocab_books"], books.stringArray == nil {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: "vocab_books",
                reason: "expected an array of strings"
            )
        }
    }

    private func requestConfiguration(
        widget: WorkflowWidget, translateTarget: String, glossary: String?
    ) throws -> LLMRequestConfiguration {
        let system: String?
        if let value = widget.props["system"] {
            switch value {
            case .null: system = nil
            case .string(let string): system = string
            default:
                throw VoiceWorkflowCompileError.invalidProperty(
                    widgetID: widget.id,
                    key: "system",
                    reason: "expected a string or null"
                )
            }
        } else {
            system = nil
        }
        let template = try stringProperty(widget, key: "user_template", default: "{text}")
        let temperature = try numberProperty(
            widget,
            key: "temperature",
            default: 0.1,
            range: 0...2
        )
        let maxTokens = try integerProperty(
            widget,
            key: "max_tokens",
            default: 4096,
            range: 1...128_000
        )
        let outputLanguage = try stringProperty(
            widget,
            key: "output_language",
            default: "auto"
        )
        return LLMRequestConfiguration(
            systemPrompt: system,
            userTemplate: template,
            temperature: temperature,
            maxTokens: maxTokens,
            outputLanguage: outputLanguage,
            translateTarget: translateTarget,
            glossary: glossary
        )
    }

    private func stringProperty(
        _ widget: WorkflowWidget, key: String, default defaultValue: String
    ) throws -> String {
        guard let value = widget.props[key] else { return defaultValue }
        guard let string = value.stringValue else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: key,
                reason: "expected a string"
            )
        }
        return string
    }

    private func numberProperty(
        _ widget: WorkflowWidget, key: String, default defaultValue: Double,
        range: ClosedRange<Double>
    ) throws -> Double {
        guard let value = widget.props[key] else { return defaultValue }
        guard let number = value.doubleValue, number.isFinite, range.contains(number) else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: key,
                reason: "expected a finite number in \(range)"
            )
        }
        return number
    }

    private func integerProperty(
        _ widget: WorkflowWidget, key: String, default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = widget.props[key] else { return defaultValue }
        guard let number = value.intValue, range.contains(number) else {
            throw VoiceWorkflowCompileError.invalidProperty(
                widgetID: widget.id,
                key: key,
                reason: "expected an integer in \(range)"
            )
        }
        return number
    }

    private func resolve<T>(widget: WorkflowWidget, operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as VoiceWorkflowCompileError {
            throw error
        } catch {
            throw VoiceWorkflowCompileError.resolutionFailed(
                widgetID: widget.id,
                reason: error.localizedDescription
            )
        }
    }
}
