import SwiftUI

struct WorkflowRecipeStrip: View {
    let definition: WorkflowDefinition
    let catalog: WorkflowCatalog
    let amber: Color
    let green: Color
    let textDim: Color

    private var nodes: [WorkflowWidget] {
        ([definition.source] + definition.processors + definition.outputs).map { id in
            catalog.widget(id: id) ?? WorkflowWidget(
                id: id,
                role: .unknown("missing"),
                typeTag: "unknown",
                name: id
            )
        }
    }

    private var pipelineNodes: [WorkflowWidget] {
        nodes.filter { $0.role != .output }
    }

    private var outputNodes: [WorkflowWidget] {
        nodes.filter { $0.role == .output }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pipelineNodes.enumerated()), id: \.offset) { index, widget in
                    node(widget)
                    if index < pipelineNodes.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(textDim.opacity(0.7))
                    }
                }
                if !pipelineNodes.isEmpty, !outputNodes.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(textDim.opacity(0.7))
                }
                if !outputNodes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outputNodes.count == 1 ? "OUTPUT" : "OUTPUTS · \(outputNodes.count)")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(textDim.opacity(0.65))
                        HStack(spacing: 5) {
                            ForEach(Array(outputNodes.enumerated()), id: \.offset) { index, widget in
                                node(widget)
                                if index < outputNodes.count - 1 {
                                    Image(systemName: "plus")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundColor(textDim.opacity(0.55))
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recipe components")
    }

    private func node(_ widget: WorkflowWidget) -> some View {
        let color = roleColor(widget.role)
        return HStack(spacing: 5) {
            Image(systemName: icon(widget))
                .font(.caption2.weight(.semibold))
            Text(widget.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.1)))
    }

    private func roleColor(_ role: WorkflowRole) -> Color {
        switch role {
        case .source: amber
        case .processor: green
        case .output: Color(red: 196/255, green: 181/255, blue: 253/255)
        case .unknown: Color.red.opacity(0.75)
        }
    }

    private func icon(_ widget: WorkflowWidget) -> String {
        switch widget.typeTag {
        case "microphone": "mic.fill"
        case "provided_audio": "waveform"
        case "stt": "text.bubble"
        case "llm": "sparkles"
        case "insert": "keyboard"
        case "clipboard": "doc.on.clipboard"
        case "return_to_caller": "arrow.uturn.backward"
        case "ios_destination": "arrow.up.forward.app"
        case "shortcut": "square.2.layers.3d"
        default: "square.grid.2x2"
        }
    }
}
