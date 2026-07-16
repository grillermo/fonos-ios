import Foundation

/// Pure translation from a NoteContainer into the parameters its STT + LLM
/// invocation actually need. Single source of truth for both the runtime
/// pipeline (NoteViewModel) and the Settings UI summary chip.
enum NotebookPipeline {

    struct Resolved: Equatable, Sendable {
        let sttLanguage: String?
        let sttModelOverride: String?
        let llm: NotebookLLMConfig?
    }

    /// Ephemeral recipe compiled for one notebook recording. Notebook settings
    /// remain SwiftData-owned, while execution uses the same schema/compiler/
    /// engine as Dictate and the keyboard.
    struct WorkflowRecipe: Equatable, Sendable {
        let definition: WorkflowDefinition
        let catalog: WorkflowCatalog
        let hasLLM: Bool
        let language: String?
    }

    static func resolve(_ n: NoteContainer) -> Resolved {
        let trimmed = n.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let llm: NotebookLLMConfig? = trimmed.isEmpty ? nil : NotebookLLMConfig(
            systemPrompt: trimmed,
            outputLanguage: n.outputLanguage ?? n.sttLanguage,
            modelOverride: n.llmModelOverride
        )
        return Resolved(
            sttLanguage: n.sttLanguage,
            sttModelOverride: n.sttModelOverride,
            llm: llm
        )
    }

    /// Compact UI label derived from the same canonical configuration as the
    /// runtime. Legacy `processingMode` is intentionally not consulted.
    static func displayLabel(for notebook: NoteContainer) -> String {
        resolve(notebook).llm == nil ? "Raw" : "AI"
    }

    static func workflowRecipe(for notebook: NoteContainer) -> WorkflowRecipe {
        let resolved = resolve(notebook)
        let namespace = "note.\(notebook.id.uuidString.lowercased())"
        let sourceID = "\(namespace).source"
        let sttID = "\(namespace).stt"
        let llmID = "\(namespace).llm"
        let outputID = "\(namespace).output"

        var widgets: [WorkflowWidget] = [
            WorkflowWidget(
                id: sourceID,
                role: .source,
                typeTag: "microphone",
                name: "Notebook microphone",
                props: .object(["capture": .string("toggle")])
            ),
            WorkflowWidget(
                id: sttID,
                role: .processor,
                typeTag: "stt",
                name: "Notebook transcription",
                props: .object([
                    "model_profile": .string(resolved.sttModelOverride ?? ""),
                    "stt_prompt": .string(""),
                    "vocab_books": .array([]),
                    "temperature": .number(0),
                    "language": .string(resolved.sttLanguage ?? "auto")
                ])
            )
        ]
        var processors = [sttID]

        if let llm = resolved.llm {
            let system = composeSystemPrompt(
                user: llm.systemPrompt,
                outputLanguage: llm.outputLanguage
            )
            widgets.append(WorkflowWidget(
                id: llmID,
                role: .processor,
                typeTag: "llm",
                name: "Notebook processing",
                props: .object([
                    "model_profile": .string(llm.modelOverride ?? ""),
                    "system": .string(system),
                    "user_template": .string("{text}"),
                    "temperature": .number(0.3),
                    "max_tokens": .integer(1_024),
                    "output_language": .string("auto"),
                    "failure_policy": .string(VoiceWorkflowLLMFailurePolicy.useInput.rawValue),
                    "vocab_books": .array([])
                ])
            ))
            processors.append(llmID)
        }

        widgets.append(WorkflowWidget(
            id: outputID,
            role: .output,
            typeTag: "return_to_caller",
            name: "Save to notebook"
        ))
        let definition = WorkflowDefinition(
            id: namespace,
            name: notebook.title,
            icon: "note.text",
            source: sourceID,
            processors: processors,
            outputs: [outputID]
        )
        return WorkflowRecipe(
            definition: definition,
            catalog: WorkflowCatalog(widgets: widgets, workflows: [definition]),
            hasLLM: resolved.llm != nil,
            language: resolved.sttLanguage
        )
    }

    static func composeSystemPrompt(user: String, outputLanguage: String?) -> String {
        guard let outputLanguage, !outputLanguage.isEmpty else { return user }
        return "Always respond in \(outputLanguage).\n\n\(user)"
    }
}

struct NotebookLLMConfig: Equatable, Sendable {
    let systemPrompt: String
    let outputLanguage: String?
    let modelOverride: String?
}
