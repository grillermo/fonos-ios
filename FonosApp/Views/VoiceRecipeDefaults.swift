import Foundation

enum VoiceRecipeID {
    static func safeComponent(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded += String(format: "_%02X", byte)
            }
        }
        if encoded.isEmpty { encoded = "recipe" }
        guard encoded.utf8.count > 56 else { return encoded }
        return String(encoded.prefix(38)) + "-" + stableHash(value)
    }

    static func unique(base: String, occupied: inout Set<String>) -> String {
        if occupied.insert(base).inserted { return base }
        var suffix = 2
        while !occupied.insert("\(base)-\(suffix)").inserted {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    static func usageCount(of widgetID: String, in catalog: WorkflowCatalog) -> Int {
        catalog.workflows.reduce(into: 0) { count, workflow in
            if workflow.source == widgetID { count += 1 }
            count += workflow.processors.filter { $0 == widgetID }.count
            count += workflow.outputs.filter { $0 == widgetID }.count
        }
    }

    static func upsert(_ widget: WorkflowWidget, into widgets: inout [WorkflowWidget]) {
        if let index = widgets.firstIndex(where: { $0.id == widget.id }) {
            widgets[index] = widget
        } else {
            widgets.append(widget)
        }
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

enum VoiceRecipeDefaults {
    static let microphoneSource = WorkflowWidget(
        id: "src.mic-hold",
        role: .source,
        typeTag: "microphone",
        name: "Microphone · Hold",
        icon: "🎙",
        props: .object(["capture": .string("hold")]),
        builtin: true
    )

    static let sttWidget = WorkflowWidget(
        id: "stt.default",
        role: .processor,
        typeTag: "stt",
        name: "Default transcription",
        icon: "✍️",
        props: .object([
            "model_profile": .string(""),
            "language": .string("auto"),
            "stt_prompt": .string(""),
            "temperature": .number(0),
            "vocab_books": .array([])
        ]),
        builtin: true
    )

    static let insertWidget = WorkflowWidget(
        id: "out.insert",
        role: .output,
        typeTag: "insert",
        name: "Insert at cursor",
        icon: "⌨️",
        props: .object([
            "strategy": .string("paste"),
            "press_enter": .bool(false)
        ]),
        builtin: true
    )

    static let clipboardWidget = WorkflowWidget(
        id: "out.clipboard",
        role: .output,
        typeTag: "clipboard",
        name: "Clipboard",
        icon: "📋",
        props: .object([:]),
        builtin: true
    )
}
