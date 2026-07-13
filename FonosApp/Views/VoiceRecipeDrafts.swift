import Foundation

// MARK: - Draft model

enum VoiceRecipeCapture: String, CaseIterable, Identifiable, Sendable {
    case hold
    case toggle

    var id: String { rawValue }
    var label: String {
        self == .hold ? String(localized: "Hold") : String(localized: "Tap to toggle")
    }
    var shortLabel: String {
        self == .hold ? String(localized: "Mic · hold") : String(localized: "Mic · toggle")
    }
    var icon: String { self == .hold ? "hand.tap.fill" : "switch.2" }
}

enum VoiceRecipeFailurePolicy: String, CaseIterable, Identifiable, Sendable {
    case useInput = "use_input"
    case failRun = "fail_run"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .useInput: String(localized: "Use this step's input")
        case .failRun: String(localized: "Stop the recipe")
        }
    }
}

struct VoiceRecipeWidgetOrigin: Equatable, Sendable {
    let original: WorkflowWidget?
    let cloneID: String
    let cloneWhenChanged: Bool

    func materialize(_ candidate: WorkflowWidget) -> (id: String, overlay: WorkflowWidget?) {
        guard let original else {
            var created = candidate
            created.id = cloneID
            created.builtin = false
            return (created.id, created)
        }

        var comparable = candidate
        comparable.id = original.id
        comparable.builtin = original.builtin
        if comparable == original {
            return (original.id, nil)
        }

        if cloneWhenChanged {
            comparable.id = cloneID
            comparable.builtin = false
        }
        return (comparable.id, comparable)
    }
}

struct VoiceRecipeSourceDraft: Equatable, Sendable {
    var origin: VoiceRecipeWidgetOrigin
    var name: String
    var icon: String
    var originalProps: WorkflowJSONValue
    var capture: VoiceRecipeCapture
    var initialCapture: VoiceRecipeCapture

    static func make(
        widget: WorkflowWidget,
        origin: VoiceRecipeWidgetOrigin
    ) -> Self {
        let capture: VoiceRecipeCapture =
            widget.props["capture"]?.stringValue == VoiceRecipeCapture.toggle.rawValue
                || widget.id == "src.mic-toggle"
                ? .toggle
                : .hold
        return Self(
            origin: origin,
            name: widget.name,
            icon: widget.icon,
            originalProps: widget.props,
            capture: capture,
            initialCapture: capture
        )
    }

    func materialize() -> (id: String, overlay: WorkflowWidget?) {
        var propsValue = originalProps
        if capture != initialCapture {
            var props = originalProps.objectValue ?? [:]
            props["capture"] = .string(capture.rawValue)
            propsValue = .object(props)
        }
        return origin.materialize(WorkflowWidget(
            id: origin.original?.id ?? origin.cloneID,
            role: .source,
            typeTag: "microphone",
            name: name,
            icon: icon,
            props: propsValue,
            builtin: origin.original?.builtin ?? false
        ))
    }
}

enum VoiceRecipeOutputKind: String, Equatable, Sendable {
    case insert
    case clipboard
}

struct VoiceRecipeOutputDraft: Equatable, Sendable {
    var origin: VoiceRecipeWidgetOrigin
    var kind: VoiceRecipeOutputKind
    var typeTag: String
    var name: String
    var icon: String
    var originalProps: WorkflowJSONValue
    var enabled: Bool
    var pressEnter: Bool
    var initialPressEnter: Bool

    var supportsPressEnter: Bool {
        kind == .insert && typeTag == "insert"
    }

    var detail: String {
        if let original = origin.original,
           original.id != canonicalID {
            return String(
                format: String(localized: "Keeps %@'s existing identity and output properties."),
                original.name
            )
        }
        switch kind {
        case .insert:
            return String(localized: "The main app returns the result; the keyboard inserts it.")
        case .clipboard:
            return String(localized: "Copies the same final text after earlier outputs succeed.")
        }
    }

    private var canonicalID: String {
        switch kind {
        case .insert: "out.insert"
        case .clipboard: "out.clipboard"
        }
    }

    static func make(
        widget: WorkflowWidget,
        kind: VoiceRecipeOutputKind,
        enabled: Bool,
        origin: VoiceRecipeWidgetOrigin
    ) -> Self {
        let pressEnter = widget.props["press_enter"]?.boolValue ?? false
        return Self(
            origin: origin,
            kind: kind,
            typeTag: widget.typeTag,
            name: widget.name,
            icon: widget.icon,
            originalProps: widget.props,
            enabled: enabled,
            pressEnter: pressEnter,
            initialPressEnter: pressEnter
        )
    }

    func materialize() -> (id: String, overlay: WorkflowWidget?)? {
        guard enabled else { return nil }
        var propsValue = originalProps
        if supportsPressEnter, pressEnter != initialPressEnter {
            var props = originalProps.objectValue ?? [:]
            props["press_enter"] = .bool(pressEnter)
            propsValue = .object(props)
        }
        return origin.materialize(WorkflowWidget(
            id: origin.original?.id ?? origin.cloneID,
            role: .output,
            typeTag: typeTag,
            name: name,
            icon: icon,
            props: propsValue,
            builtin: origin.original?.builtin ?? false
        ))
    }
}

struct VoiceRecipeSTTDraft: Equatable, Sendable {
    var origin: VoiceRecipeWidgetOrigin
    var name: String
    var icon: String
    var modelProfileID: String
    var language: String
    var prompt: String
    var temperature: Double
    var vocabBookIDs: [String]
    var baseProps: [String: WorkflowJSONValue]

    static func make(widget: WorkflowWidget, origin: VoiceRecipeWidgetOrigin) -> Self {
        let props = widget.props.objectValue ?? [:]
        return Self(
            origin: origin,
            name: widget.name,
            icon: widget.icon,
            modelProfileID: props["model_profile"]?.stringValue ?? "",
            language: props["language"]?.stringValue ?? "auto",
            prompt: props["stt_prompt"]?.stringValue ?? "",
            temperature: min(1, max(0, props["temperature"]?.doubleValue ?? 0)),
            vocabBookIDs: props["vocab_books"]?.stringArray ?? [],
            baseProps: props
        )
    }

    func materialize() -> (id: String, overlay: WorkflowWidget?) {
        var props = baseProps
        props["model_profile"] = .string(modelProfileID)
        props["language"] = .string(language)
        props["stt_prompt"] = .string(prompt)
        props["temperature"] = .number(temperature)
        props["vocab_books"] = .array(vocabBookIDs.map(WorkflowJSONValue.string))
        return origin.materialize(WorkflowWidget(
            id: origin.original?.id ?? origin.cloneID,
            role: .processor,
            typeTag: "stt",
            name: name,
            icon: icon,
            props: .object(props),
            builtin: origin.original?.builtin ?? false
        ))
    }
}

/// Pure, UI-independent recipe editing state. Keeping materialization here
/// makes copy-on-write widget identity, unknown property preservation and
/// ordered processor/output assembly directly testable without rendering the
/// SwiftUI editor.
struct VoiceRecipeDraft: Equatable, Sendable {
    var originalDefinition: WorkflowDefinition?
    var workflowID: String
    var name: String
    var icon: String
    var source: VoiceRecipeSourceDraft
    var stt: VoiceRecipeSTTDraft
    var llms: [VoiceRecipeLLMDraft]
    var insertOutput: VoiceRecipeOutputDraft
    var clipboardOutput: VoiceRecipeOutputDraft
    var outputOrder: [VoiceRecipeOutputKind]
    var blockingIssues: [String]
    var occupiedWidgetIDs: Set<String>
    var nextLLMSequence: Int

    static func make(
        definition: WorkflowDefinition?,
        catalog: WorkflowCatalog
    ) -> Self {
        let workflowID = definition?.id ?? "wf.custom-\(UUID().uuidString.lowercased())"
        let base = definition ?? WorkflowDefinition(
            id: workflowID,
            name: String(localized: "New voice recipe"),
            icon: "🎙",
            source: "src.mic-hold",
            processors: ["stt.default"],
            outputs: ["out.insert"]
        )

        var occupied = Set(catalog.widgets.map(\.id))
        var issues: [String] = []
        let component = VoiceRecipeID.safeComponent(workflowID)
        let source = makeSource(
            sourceID: base.source,
            hasOriginalDefinition: definition != nil,
            component: component,
            catalog: catalog,
            occupied: &occupied,
            issues: &issues
        )
        let processors = makeProcessors(
            processorIDs: base.processors,
            component: component,
            catalog: catalog,
            occupied: &occupied,
            issues: &issues
        )
        let outputs = makeOutputs(
            outputIDs: base.outputs,
            component: component,
            catalog: catalog,
            occupied: &occupied,
            issues: &issues
        )

        return Self(
            originalDefinition: definition,
            workflowID: workflowID,
            name: base.name,
            icon: base.icon,
            source: source,
            stt: processors.stt,
            llms: processors.llms,
            insertOutput: outputs.insert,
            clipboardOutput: outputs.clipboard,
            outputOrder: outputs.order,
            blockingIssues: issues,
            occupiedWidgetIDs: occupied,
            nextLLMSequence: processors.llms.count + 1
        )
    }

    private static func makeSource(
        sourceID: String,
        hasOriginalDefinition: Bool,
        component: String,
        catalog: WorkflowCatalog,
        occupied: inout Set<String>,
        issues: inout [String]
    ) -> VoiceRecipeSourceDraft {
        let sourceWidget = catalog.widget(id: sourceID)
        let originalSource: WorkflowWidget
        if let sourceWidget,
           sourceWidget.role == .source,
           sourceWidget.typeTag == "microphone" {
            originalSource = sourceWidget
        } else {
            if hasOriginalDefinition, sourceWidget == nil {
                issues.append("The recipe's source component is missing.")
            } else if hasOriginalDefinition {
                issues.append("This guided editor only supports microphone recipes.")
            }
            originalSource = catalog.widget(id: "src.mic-hold")
                ?? VoiceRecipeDefaults.microphoneSource
        }

        let cloneID = VoiceRecipeID.unique(
            base: "src.mic.recipe-\(component)",
            occupied: &occupied
        )
        let origin = VoiceRecipeWidgetOrigin(
            original: originalSource,
            cloneID: cloneID,
            cloneWhenChanged: originalSource.builtin
                || VoiceRecipeID.usageCount(of: originalSource.id, in: catalog) > 1
        )
        return VoiceRecipeSourceDraft.make(
            widget: originalSource,
            origin: origin
        )
    }
    private struct ProcessorDrafts {
        let stt: VoiceRecipeSTTDraft
        let llms: [VoiceRecipeLLMDraft]
    }

    private static func makeProcessors(
        processorIDs: [String],
        component: String,
        catalog: WorkflowCatalog,
        occupied: inout Set<String>,
        issues: inout [String]
    ) -> ProcessorDrafts {
        let processorWidgets = processorIDs.map { id in
            (id: id, widget: catalog.widget(id: id))
        }
        let originalSTT: WorkflowWidget
        var llmEntries: [(id: String, widget: WorkflowWidget)] = []

        if let first = processorWidgets.first,
           let widget = first.widget,
           widget.role == .processor,
           widget.typeTag == "stt" {
            originalSTT = widget
            for entry in processorWidgets.dropFirst() {
                guard let widget = entry.widget else {
                    issues.append("Processor '\(entry.id)' is missing.")
                    continue
                }
                guard widget.role == .processor, widget.typeTag == "llm" else {
                    issues.append("Processor '\(entry.id)' is not supported by this guided editor.")
                    continue
                }
                llmEntries.append((entry.id, widget))
            }
        } else {
            if !processorWidgets.isEmpty {
                issues.append("A microphone recipe must begin with one STT processor.")
            }
            originalSTT = catalog.widget(id: "stt.default") ?? VoiceRecipeDefaults.sttWidget
        }

        let sttCloneID = VoiceRecipeID.unique(
            base: "stt.recipe-\(component)",
            occupied: &occupied
        )
        let sttOrigin = VoiceRecipeWidgetOrigin(
            original: originalSTT,
            cloneID: sttCloneID,
            cloneWhenChanged: originalSTT.builtin
                || VoiceRecipeID.usageCount(of: originalSTT.id, in: catalog) > 1
        )
        let stt = VoiceRecipeSTTDraft.make(widget: originalSTT, origin: sttOrigin)

        var llms: [VoiceRecipeLLMDraft] = []
        for (index, entry) in llmEntries.enumerated() {
            let cloneID = VoiceRecipeID.unique(
                base: "llm.recipe-\(component)-\(index + 1)",
                occupied: &occupied
            )
            let origin = VoiceRecipeWidgetOrigin(
                original: entry.widget,
                cloneID: cloneID,
                cloneWhenChanged: entry.widget.builtin
                    || VoiceRecipeID.usageCount(of: entry.widget.id, in: catalog) > 1
            )
            llms.append(.make(widget: entry.widget, origin: origin))
        }
        return ProcessorDrafts(stt: stt, llms: llms)
    }

    private struct OutputDrafts {
        let insert: VoiceRecipeOutputDraft
        let clipboard: VoiceRecipeOutputDraft
        let order: [VoiceRecipeOutputKind]
    }

    private static func makeOutputs(
        outputIDs: [String],
        component: String,
        catalog: WorkflowCatalog,
        occupied: inout Set<String>,
        issues: inout [String]
    ) -> OutputDrafts {
        var originalInsertOutput: WorkflowWidget?
        var originalClipboardOutput: WorkflowWidget?
        var outputOrder: [VoiceRecipeOutputKind] = []
        for outputID in outputIDs {
            guard let widget = catalog.widget(id: outputID) else {
                issues.append("Output '\(outputID)' is missing.")
                continue
            }
            guard widget.role == .output else {
                issues.append("Output '\(outputID)' does not have the output role.")
                continue
            }
            switch widget.typeTag {
            case "insert", "return_to_caller":
                guard originalInsertOutput == nil else {
                    issues.append("This guided editor supports one insertion output per recipe.")
                    continue
                }
                originalInsertOutput = widget
                outputOrder.append(.insert)
            case "clipboard":
                guard originalClipboardOutput == nil else {
                    issues.append("This guided editor supports one clipboard output per recipe.")
                    continue
                }
                originalClipboardOutput = widget
                outputOrder.append(.clipboard)
            default:
                issues.append("Output '\(outputID)' is not supported by this guided editor.")
            }
        }

        let insertWidget = originalInsertOutput
            ?? catalog.widget(id: "out.insert")
            ?? VoiceRecipeDefaults.insertWidget
        let insertCloneID = VoiceRecipeID.unique(
            base: "out.insert.recipe-\(component)",
            occupied: &occupied
        )
        let insertOutput = VoiceRecipeOutputDraft.make(
            widget: insertWidget,
            kind: .insert,
            enabled: originalInsertOutput != nil,
            origin: VoiceRecipeWidgetOrigin(
                original: insertWidget,
                cloneID: insertCloneID,
                cloneWhenChanged: insertWidget.builtin
                    || VoiceRecipeID.usageCount(of: insertWidget.id, in: catalog) > 1
            )
        )

        let clipboardWidget = originalClipboardOutput
            ?? catalog.widget(id: "out.clipboard")
            ?? VoiceRecipeDefaults.clipboardWidget
        let clipboardCloneID = VoiceRecipeID.unique(
            base: "out.clipboard.recipe-\(component)",
            occupied: &occupied
        )
        let clipboardOutput = VoiceRecipeOutputDraft.make(
            widget: clipboardWidget,
            kind: .clipboard,
            enabled: originalClipboardOutput != nil,
            origin: VoiceRecipeWidgetOrigin(
                original: clipboardWidget,
                cloneID: clipboardCloneID,
                cloneWhenChanged: clipboardWidget.builtin
                    || VoiceRecipeID.usageCount(of: clipboardWidget.id, in: catalog) > 1
            )
        )

        return OutputDrafts(
            insert: insertOutput,
            clipboard: clipboardOutput,
            order: outputOrder
        )
    }

    mutating func appendLLM() -> UUID {
        let component = VoiceRecipeID.safeComponent(workflowID)
        let widgetID = VoiceRecipeID.unique(
            base: "llm.recipe-\(component)-\(nextLLMSequence)",
            occupied: &occupiedWidgetIDs
        )
        nextLLMSequence += 1
        let llm = VoiceRecipeLLMDraft.fresh(
            origin: VoiceRecipeWidgetOrigin(
                original: nil,
                cloneID: widgetID,
                cloneWhenChanged: false
            ),
            vocabBookIDs: stt.vocabBookIDs
        )
        llms.append(llm)
        return llm.id
    }

    func materializedResult() -> VoiceRecipeEditorResult {
        var overlays: [WorkflowWidget] = []
        let sourceResult = source.materialize()
        if let overlay = sourceResult.overlay {
            VoiceRecipeID.upsert(overlay, into: &overlays)
        }

        let sttResult = stt.materialize()
        if let overlay = sttResult.overlay {
            VoiceRecipeID.upsert(overlay, into: &overlays)
        }

        var processors = [sttResult.id]
        for llm in llms {
            let result = llm.materialize()
            processors.append(result.id)
            if let overlay = result.overlay {
                VoiceRecipeID.upsert(overlay, into: &overlays)
            }
        }

        let insertResult = insertOutput.materialize()
        let clipboardResult = clipboardOutput.materialize()
        if let overlay = insertResult?.overlay {
            VoiceRecipeID.upsert(overlay, into: &overlays)
        }
        if let overlay = clipboardResult?.overlay {
            VoiceRecipeID.upsert(overlay, into: &overlays)
        }

        var orderedKinds = outputOrder
        if insertResult != nil, !orderedKinds.contains(.insert) {
            orderedKinds.append(.insert)
        }
        if clipboardResult != nil, !orderedKinds.contains(.clipboard) {
            orderedKinds.append(.clipboard)
        }
        let outputs = orderedKinds.compactMap { kind -> String? in
            switch kind {
            case .insert: insertResult?.id
            case .clipboard: clipboardResult?.id
            }
        }

        let definition = WorkflowDefinition(
            id: workflowID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon.trimmingCharacters(in: .whitespacesAndNewlines),
            hotkey: originalDefinition?.hotkey ?? "",
            triggers: originalDefinition?.triggers ?? [],
            source: sourceResult.id,
            processors: processors,
            outputs: outputs,
            builtin: originalDefinition?.builtin ?? false
        )
        return VoiceRecipeEditorResult(
            definition: definition,
            widgetOverlays: overlays
        )
    }
}
