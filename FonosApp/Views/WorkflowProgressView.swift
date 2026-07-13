import SwiftUI

/// Shared status projection used by the progress card and the surrounding
/// dictation controls. Keeping this mapping in one place prevents the header,
/// record hint, and workflow card from describing different execution phases.
struct WorkflowProgressStatus {
    let presentation: WorkflowRunPresentation

    var text: String {
        switch presentation.phase {
        case .idle:
            return String(localized: "Ready")
        case .running:
            let current = presentation.nodes.first(where: { $0.state == .running })
            return current.map { String(localized: "Running \($0.name)…") }
                ?? String(localized: "Preparing flow…")
        case .succeeded:
            return String(localized: "Flow complete")
        case .degraded:
            return String(localized: "Transcript fallback")
        case .failed:
            return String(localized: "Flow failed")
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    var color: Color {
        switch presentation.phase {
        case .running, .degraded:
            return Color(hex: "#fbbf24")
        case .succeeded:
            return Color(hex: "#86efac")
        case .failed:
            return Color(hex: "#ef4444")
        case .idle, .cancelled:
            return Color.white.opacity(0.5)
        }
    }

    var accessibilityValue: String {
        switch presentation.phase {
        case .idle: return String(localized: "Ready")
        case .running: return text
        case .succeeded: return String(localized: "Flow complete")
        case .degraded: return String(localized: "AI unavailable — transcript used")
        case .failed: return String(localized: "Flow failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

/// Renders the actual source → processor → output topology and live trace from
/// `WorkflowRunPresentation`. Preview nodes are supplied by the same view model
/// when no run is active, so idle and running layouts remain identical.
struct WorkflowProgressView: View {
    @ObservedObject var viewModel: DictationViewModel

    private struct NodeAppearance {
        let icon: String
        let color: Color
        let isEmphasized: Bool
    }

    private var status: WorkflowProgressStatus {
        WorkflowProgressStatus(presentation: viewModel.workflowPresentation)
    }

    private var pipelineNodes: [WorkflowRunPresentation.Node] {
        viewModel.workflowDisplayNodes.filter { $0.role != .output }
    }

    private var outputNodes: [WorkflowRunPresentation.Node] {
        viewModel.workflowDisplayNodes.filter { $0.role == .output }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(viewModel.activeWorkflowDefinition?.name ?? String(localized: "Voice flow"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(status.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(status.color)
                    .lineLimit(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(pipelineNodes.enumerated()), id: \.element.id) { offset, node in
                        workflowNode(node)
                        if offset < pipelineNodes.count - 1 {
                            workflowConnector(after: node)
                        }
                    }

                    if let lastPipelineNode = pipelineNodes.last,
                       !outputNodes.isEmpty {
                        workflowConnector(after: lastPipelineNode)
                        workflowOutputGroup(outputNodes)
                    }
                }
                .padding(.vertical, 1)
            }

            if viewModel.activeVocabularyTermCount > 0 {
                Label(
                    "\(viewModel.activeVocabularyTermCount) vocabulary terms applied inside transcription",
                    systemImage: "text.badge.checkmark"
                )
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(hex: "#86efac").opacity(0.65))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Color(hex: "#fafaf9").opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(Color(hex: "#fafaf9").opacity(0.07), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flow progress")
        .accessibilityValue(status.accessibilityValue)
        .accessibilityIdentifier("flow-progress")
    }

    private func workflowOutputGroup(
        _ outputs: [WorkflowRunPresentation.Node]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(outputs.count == 1 ? "OUTPUT" : "OUTPUTS · \(outputs.count)")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(
                    Color(red: 196/255, green: 181/255, blue: 253/255).opacity(0.62)
                )

            HStack(spacing: 5) {
                ForEach(Array(outputs.enumerated()), id: \.element.id) { offset, node in
                    workflowNode(node)
                    if offset < outputs.count - 1 {
                        Image(systemName: "plus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.26))
                    }
                }
            }
        }
        .padding(.horizontal, outputs.count > 1 ? 7 : 0)
        .padding(.vertical, outputs.count > 1 ? 5 : 0)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(outputs.count > 1 ? Color.white.opacity(0.025) : .clear)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outputs, \(outputs.count)")
    }

    private func workflowNode(_ node: WorkflowRunPresentation.Node) -> some View {
        let appearance = workflowAppearance(for: node)

        return HStack(spacing: 5) {
            Image(systemName: appearance.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(appearance.color)
                .symbolEffect(.pulse, options: .repeating, isActive: node.state == .running)

            Text(node.name)
                .font(.system(size: 10, weight: appearance.isEmphasized ? .semibold : .medium))
                .foregroundColor(appearance.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(appearance.color.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workflow-step-\(node.index)")
    }

    private func workflowConnector(after node: WorkflowRunPresentation.Node) -> some View {
        let isComplete: Bool
        switch node.state {
        case .succeeded, .fallback: isComplete = true
        case .pending, .running, .failed, .cancelled, .intercepted: isComplete = false
        }

        return Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(
                isComplete ? Color(hex: "#86efac").opacity(0.6) : Color.white.opacity(0.2)
            )
    }

    private func workflowAppearance(for node: WorkflowRunPresentation.Node) -> NodeAppearance {
        let roleColor: Color
        switch node.role {
        case .source: roleColor = Color(hex: "#fbbf24")
        case .processor: roleColor = Color(hex: "#86efac")
        case .output: roleColor = Color(red: 196/255, green: 181/255, blue: 253/255)
        case .unknown: roleColor = Color.white.opacity(0.5)
        }
        switch node.state {
        case .pending:
            return NodeAppearance(
                icon: workflowIcon(for: node),
                color: roleColor.opacity(0.62),
                isEmphasized: false
            )
        case .running:
            return NodeAppearance(
                icon: "ellipsis.circle.fill",
                color: Color(hex: "#fbbf24"),
                isEmphasized: true
            )
        case .succeeded:
            return NodeAppearance(icon: "checkmark.circle.fill", color: roleColor, isEmphasized: true)
        case .fallback:
            return NodeAppearance(
                icon: "exclamationmark.circle.fill",
                color: Color(hex: "#fbbf24"),
                isEmphasized: true
            )
        case .failed:
            return NodeAppearance(
                icon: "xmark.circle.fill",
                color: Color(hex: "#ef4444"),
                isEmphasized: true
            )
        case .cancelled:
            return NodeAppearance(
                icon: "xmark.circle",
                color: Color.white.opacity(0.4),
                isEmphasized: false
            )
        case .intercepted:
            return NodeAppearance(
                icon: "arrow.uturn.backward.circle",
                color: roleColor.opacity(0.7),
                isEmphasized: false
            )
        }
    }

    private func workflowIcon(for node: WorkflowRunPresentation.Node) -> String {
        switch node.typeTag {
        case "microphone": return "mic.fill"
        case "provided_audio": return "waveform"
        case "stt": return "text.bubble"
        case "llm": return "sparkles"
        case "insert": return "keyboard"
        case "clipboard": return "doc.on.clipboard"
        case "return_to_caller": return "arrow.uturn.backward"
        case "ios_destination": return "arrow.up.forward.app"
        default:
            return node.role == .output ? "arrow.up.forward.app" : "square.grid.2x2"
        }
    }
}

struct WorkflowOutcomeBadge: View {
    @ObservedObject var viewModel: DictationViewModel

    private struct Appearance {
        let icon: String
        let text: String
        let color: Color
    }

    private var appearance: Appearance {
        let green = Color(hex: "#86efac")
        let amber = Color(hex: "#fbbf24")
        switch viewModel.workflowPresentation.phase {
        case .degraded:
            return Appearance(
                icon: "arrow.uturn.backward",
                text: String(localized: "AI unavailable — transcript used"),
                color: amber
            )
        case .succeeded where viewModel.activeWorkflowUsesLLM && viewModel.llmProviderName != nil:
            return Appearance(
                icon: "sparkles",
                text: String(localized: "AI processing complete"),
                color: green
            )
        case .succeeded where viewModel.activeWorkflowUsesLLM:
            return Appearance(
                icon: "exclamationmark.triangle.fill",
                text: String(localized: "No LLM configured — transcript used"),
                color: amber
            )
        case .idle, .running, .succeeded, .failed, .cancelled:
            return Appearance(
                icon: "text.badge.checkmark",
                text: String(localized: "Transcript ready"),
                color: green
            )
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: appearance.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(appearance.text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(appearance.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(appearance.color.opacity(0.09))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Flow result")
        .accessibilityValue(appearance.text)
        .accessibilityIdentifier("flow-outcome")
    }
}
