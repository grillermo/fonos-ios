import Foundation

struct VoiceRecipeLLMDraft: Equatable, Identifiable, Sendable {
    let id: UUID
    var origin: VoiceRecipeWidgetOrigin
    var name: String
    var icon: String
    var modelProfileID: String
    var outputLanguage: String
    var systemPrompt: String
    var userTemplate: String
    var temperature: Double
    var maxTokens: Int
    var failurePolicy: VoiceRecipeFailurePolicy
    var vocabBookIDs: [String]
    var baseProps: [String: WorkflowJSONValue]
    var originalSystemWasNull: Bool
    var originalOutputLanguageWasPresent: Bool

    var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "AI processor") : trimmed
    }

    static func make(widget: WorkflowWidget, origin: VoiceRecipeWidgetOrigin) -> Self {
        let props = widget.props.objectValue ?? [:]
        let policy = VoiceRecipeFailurePolicy(
            rawValue: props["failure_policy"]?.stringValue ?? VoiceRecipeFailurePolicy.useInput.rawValue
        ) ?? .useInput
        let system: String
        let wasNull: Bool
        if props["system"] == .null {
            system = ""
            wasNull = true
        } else {
            system = props["system"]?.stringValue ?? ""
            wasNull = false
        }
        return Self(
            id: UUID(),
            origin: origin,
            name: widget.name,
            icon: widget.icon,
            modelProfileID: props["model_profile"]?.stringValue ?? "",
            outputLanguage: props["output_language"]?.stringValue ?? "auto",
            systemPrompt: system,
            userTemplate: props["user_template"]?.stringValue ?? "{text}",
            temperature: min(2, max(0, props["temperature"]?.doubleValue ?? 0.1)),
            maxTokens: min(128_000, max(1, props["max_tokens"]?.intValue ?? 4096)),
            failurePolicy: policy,
            vocabBookIDs: props["vocab_books"]?.stringArray ?? [],
            baseProps: props,
            originalSystemWasNull: wasNull,
            originalOutputLanguageWasPresent: props["output_language"] != nil
        )
    }

    static func fresh(
        origin: VoiceRecipeWidgetOrigin,
        vocabBookIDs: [String]
    ) -> Self {
        let definition = WorkflowCanonicalLLM.polish
        return Self(
            id: UUID(),
            origin: origin,
            name: String(localized: "Polish text"),
            icon: "✨",
            modelProfileID: "",
            outputLanguage: "auto",
            systemPrompt: definition.system,
            userTemplate: definition.userTemplate,
            temperature: definition.temperature,
            maxTokens: Int(definition.maxTokens),
            failurePolicy: .useInput,
            vocabBookIDs: vocabBookIDs,
            baseProps: [:],
            originalSystemWasNull: false,
            originalOutputLanguageWasPresent: true
        )
    }

    func materialize() -> (id: String, overlay: WorkflowWidget?) {
        var props = baseProps
        if originalSystemWasNull && systemPrompt.isEmpty {
            props["system"] = .null
        } else {
            props["system"] = .string(systemPrompt)
        }
        props["user_template"] = .string(userTemplate)
        props["model_profile"] = .string(modelProfileID)
        props["temperature"] = .number(temperature)
        props["max_tokens"] = .integer(Int64(maxTokens))
        props["failure_policy"] = .string(failurePolicy.rawValue)
        props["vocab_books"] = .array(vocabBookIDs.map(WorkflowJSONValue.string))
        if originalOutputLanguageWasPresent || outputLanguage != "auto" {
            props["output_language"] = .string(outputLanguage)
        }
        return origin.materialize(WorkflowWidget(
            id: origin.original?.id ?? origin.cloneID,
            role: .processor,
            typeTag: "llm",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            props: .object(props),
            builtin: origin.original?.builtin ?? false
        ))
    }
}
