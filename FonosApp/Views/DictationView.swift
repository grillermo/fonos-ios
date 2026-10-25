import SwiftUI
import os.log

private let viewLog = Logger(subsystem: "com.fonos.ios", category: "DictationView")

/// Main dictation recording screen.
struct DictationView: View {
    @ObservedObject var viewModel: DictationViewModel
    @State private var showCopiedFeedback = false
    @State private var editedResult = ""
    @FocusState private var isEditingResult: Bool

    /// Convenience initialiser for previews and unit tests.
    /// Uses a default no-op DictationViewModel (no STT provider).
    init(viewModel: DictationViewModel = DictationViewModel()) {
        self.viewModel = viewModel
    }

    var body: some View {
        ZStack {
            Color(hex: "#1a1917")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Header
                headerView
                    .padding(.top, 8)
                    .padding(.horizontal, 20)

                // MARK: - Mode Picker Strip
                // Nothing to choose between with a single mode.
                if voiceWorkflows.count > 1 {
                    modePickerStrip
                        .padding(.top, 12)
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 20)

                // MARK: - Waveform + Button (compact, pushed up)
                WaveformView(
                    audioLevel: viewModel.audioLevel,
                    isRecording: viewModel.isRecording
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                recordButtonSection

                // MARK: - Model Info
                modelInfoLabel
                    .padding(.top, 12)

                // MARK: - Actual recipe execution
                WorkflowProgressView(viewModel: viewModel)
                    .padding(.top, 10)
                    .padding(.horizontal, 20)

                Spacer(minLength: 12)

                // MARK: - Result / Error Area (scrollable)
                ScrollView {
                    VStack(spacing: 12) {
                        if case .result(let transcript, let processed) = viewModel.recordingState {
                            resultCard(transcript: transcript, processed: processed)
                        }

                        if case .error(let message) = viewModel.recordingState {
                            errorCard(message: message)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 240)

                // MARK: - Latency
                if viewModel.workflowPresentation.totalDuration != nil {
                    latencyView
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
        }
        .background { recordShortcut }
        .onAppear { editedResult = resultText ?? "" }
        .onChange(of: viewModel.recordingState) {
            if let resultText { editedResult = resultText }
        }
        .onChange(of: isEditingResult) { _, editing in
            if !editing { viewModel.updateResultText(editedResult) }
        }
    }

    /// Return on a hardware keyboard starts or stops a recording, like a tap
    /// on the record button. The button is invisible; it exists only to carry
    /// the shortcut.
    private var recordShortcut: some View {
        Button("Toggle Recording") { handleRecordTap() }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(viewModel.recordingState == .processing || isEditingResult)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Fonos")
                .font(.system(size: 22, weight: .bold, design: .default))
                .foregroundColor(Color(hex: "#fafaf9"))

            Spacer()

            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.6))
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.recordingState {
        case .idle:       return Color(hex: "#fafaf9").opacity(0.3)
        case .starting:   return Color(hex: "#f59e0b")
        case .recording:  return Color(hex: "#ef4444")
        case .processing: return Color(hex: "#fbbf24")
        case .result:     return Color(hex: "#86efac")
        case .error:      return Color(hex: "#ef4444")
        }
    }

    private var statusText: String {
        switch viewModel.recordingState {
        case .idle:       return String(localized: "Ready")
        case .starting:   return String(localized: "Starting…")
        case .recording:  return String(localized: "Recording")
        case .processing: return activeFlowStatus
        case .result:     return String(localized: "Done")
        case .error:      return String(localized: "Error")
        }
    }

    private var activeFlowStatus: String {
        WorkflowProgressStatus(presentation: viewModel.workflowPresentation).text
    }

    // MARK: - Mode Picker Strip

    private var modePickerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(voiceWorkflows, id: \.id) { workflow in
                    modeChip(workflow)
                }
            }
            .padding(.horizontal, 4)
        }
        .allowsHitTesting(!isModeSelectionLocked)
        .opacity(isModeSelectionLocked ? 0.65 : 1)
        .animation(.easeOut(duration: 0.2), value: isModeSelectionLocked)
    }

    private func modeChip(_ workflow: WorkflowDefinition) -> some View {
        let isSelected = viewModel.config.activeVoiceWorkflowID == workflow.id
        let isAvailable = isWorkflowRunnable(workflow)
        return Button {
            viewModel.selectMode(id: workflow.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isAvailable ? workflowSymbol(workflow) : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                Text(workflowDisplayName(workflow))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .lineLimit(1)
            .foregroundColor(
                !isAvailable
                    ? Color(hex: "#ef4444").opacity(0.75)
                    : (isSelected ? Color(hex: "#1a1917") : Color(hex: "#fafaf9").opacity(0.7))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color(hex: "#fbbf24") : Color(hex: "#fafaf9").opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isSelected ? Color.clear : Color(hex: "#fafaf9").opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isAvailable)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .accessibilityIdentifier(
            "mode-\(WorkflowMigration.legacyModeID(forWorkflowID: workflow.id) ?? workflow.id)"
        )
    }

    private var voiceWorkflows: [WorkflowDefinition] {
        viewModel.config.enabledVoiceWorkflows
    }

    private func isWorkflowRunnable(_ workflow: WorkflowDefinition) -> Bool {
        (try? VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: workflow,
            catalog: viewModel.config.workflowCatalog,
            config: viewModel.config
        )) != nil
    }

    private func workflowDisplayName(_ workflow: WorkflowDefinition) -> String {
        switch workflow.id {
        case "wf.dictation" where workflow.name == "Raw": return String(localized: "Raw")
        case "wf.voice.polish" where workflow.name == "Polish": return String(localized: "Polish")
        case "wf.voice.formal" where workflow.name == "Formal": return String(localized: "Formal")
        case "wf.voice.translate" where workflow.name == "Translate": return String(localized: "Translate")
        default: return workflow.name
        }
    }

    private func workflowSymbol(_ workflow: WorkflowDefinition) -> String {
        switch workflow.id {
        case "wf.dictation": return "waveform"
        case "wf.voice.polish": return "sparkles"
        case "wf.voice.formal": return "briefcase"
        case "wf.voice.translate": return "globe"
        default:
            return !workflow.icon.isEmpty
                && workflow.icon.unicodeScalars.allSatisfy { $0.isASCII }
                ? workflow.icon
                : "point.3.connected.trianglepath.dotted"
        }
    }

    private var isModeSelectionLocked: Bool {
        switch viewModel.recordingState {
        case .starting, .recording, .processing: return true
        case .idle, .result, .error: return false
        }
    }

    // MARK: - Record Button Section

    private var recordButtonSection: some View {
        VStack(spacing: 16) {
            RecordButton(
                state: recordButtonState,
                onTap: handleRecordTap,
                onPressingChanged: holdHandler
            )

            Text(recordButtonHint)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(
                    viewModel.isRecording ? Color.red : Color.white.opacity(0.5)
                )
        }
    }

    private var recordButtonState: RecordButton.ButtonState {
        switch viewModel.recordingState {
        case .idle, .result, .error: return .idle
        case .starting:              return .starting
        case .recording:             return .recording
        case .processing:            return .processing
        }
    }

    private var recordButtonHint: String {
        let holdMode = viewModel.activeRecordMode == .hold
        switch viewModel.recordingState {
        case .idle:
            return holdMode ? String(localized: "Hold to dictate") : String(localized: "Tap to dictate")
        case .starting:
            return holdMode ? String(localized: "Release to cancel") : String(localized: "Tap to cancel")
        case .recording:
            return holdMode ? String(localized: "Release to stop") : String(localized: "Tap to stop")
        case .processing:
            return activeFlowStatus
        case .result:
            return holdMode ? String(localized: "Hold to record again") : String(localized: "Tap to record again")
        case .error:
            return holdMode ? String(localized: "Hold to try again") : String(localized: "Tap to try again")
        }
    }

    // MARK: - Model Info Label

    private var modelInfoLabel: some View {
        HStack(spacing: 6) {
            // STT model indicator
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                Text(viewModel.sttProviderName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(Color.orange.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.orange.opacity(0.08))
            )

            // Mode + LLM indicator
            HStack(spacing: 4) {
                Image(systemName: viewModel.activeWorkflowDefinition.map(workflowSymbol) ?? "waveform")
                    .font(.system(size: 9))
                Text(activeModeDisplayName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if viewModel.activeWorkflowUsesLLM {
                    Text("·")
                    if let llmName = viewModel.llmProviderName {
                        Text(llmName)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                    } else {
                        Text("No LLM")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.3))
                    }
                }
            }
            .foregroundColor(Color(red: 134/255, green: 239/255, blue: 172/255).opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color(red: 134/255, green: 239/255, blue: 172/255).opacity(0.08))
            )
        }
    }

    private var activeModeDisplayName: String {
        viewModel.activeWorkflowDefinition.map(workflowDisplayName)
            ?? String(localized: "Voice flow")
    }

    /// Non-nil only in hold mode — switches RecordButton to press-and-hold.
    private var holdHandler: ((Bool) -> Void)? {
        guard viewModel.activeRecordMode == .hold else { return nil }
        return handleHoldChange
    }

    /// Press-and-hold handling (RecordMode.hold): touch-down starts, release stops.
    private func handleHoldChange(_ pressing: Bool) {
        let action = DictationViewModel.holdGestureAction(
            pressing: pressing,
            state: viewModel.recordingState,
            recordMode: viewModel.activeRecordMode
        )
        viewLog.info("✊ handleHoldChange(pressing: \(pressing)) → \(String(describing: action))")
        switch action {
        case .start: viewModel.startRecording()
        case .stop:  viewModel.stopRecording()
        case .none:  break
        }
    }

    private func handleRecordTap() {
        // Keep an in-progress edit before the result card goes away.
        if isEditingResult {
            viewModel.updateResultText(editedResult)
            isEditingResult = false
        }
        viewLog.info("👆 handleRecordTap() — current state: \(String(describing: viewModel.recordingState))")
        switch viewModel.recordingState {
        case .idle, .result, .error:
            viewLog.info("👆 → calling startRecording()")
            viewModel.startRecording()
        case .starting, .recording:
            viewLog.info("👆 → calling stopRecording()")
            viewModel.stopRecording()
        case .processing:
            viewLog.info("👆 → processing, ignoring tap")
        }
    }
}

private extension DictationView {
    // MARK: - Result Card

    private func resultCard(transcript: String, processed: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "#86efac"))
                Text("Result")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#86efac"))
                Spacer()

                if showCopiedFeedback {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundColor(Color(hex: "#86efac"))
                    .transition(.opacity)
                }

                if isEditingResult {
                    Button("Done & Copy") {
                        isEditingResult = false
                        copyResult()
                    }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#fbbf24"))
                } else {
                    Button(action: copyResult) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: "#fbbf24"))
                    }
                    .accessibilityLabel("Copy")
                }
            }

            WorkflowOutcomeBadge(viewModel: viewModel)

            // Editable: changes replace the result and its History entry
            // when editing ends.
            TextEditor(text: $editedResult)
                .focused($isEditingResult)
                .font(.system(size: 16))
                .foregroundColor(Color(hex: "#fafaf9"))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: 200)
                .padding(.horizontal, -5)

            if processed != nil && processed != transcript {
                Divider()
                    .background(Color(hex: "#fafaf9").opacity(0.1))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Original")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.4))
                    Text(transcript)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.5))
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "#fafaf9").opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color(hex: "#fafaf9").opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func copyResult() {
        UIPasteboard.general.string = editedResult
        withAnimation {
            showCopiedFeedback = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation {
                showCopiedFeedback = false
            }
        }
    }

    /// Text shown for the current result, or nil when there is none.
    private var resultText: String? {
        guard case .result(let transcript, let processed) = viewModel.recordingState else { return nil }
        return processed ?? transcript
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color(hex: "#ef4444"))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#fafaf9").opacity(0.8))
                .lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "#ef4444").opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color(hex: "#ef4444").opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Latency

    private var latencyView: some View {
        return HStack(spacing: 16) {
            if viewModel.sttLatency > 0 {
                latencyBadge(label: "STT", seconds: viewModel.sttLatency)
            }
            if viewModel.llmLatency > 0 {
                latencyBadge(label: "AI", seconds: viewModel.llmLatency)
            }
            if let total = viewModel.workflowPresentation.totalDuration,
               total > 0 {
                latencyBadge(label: String(localized: "Total"), seconds: total)
            }
            Spacer()
        }
    }

    private func latencyBadge(label: String, seconds: TimeInterval) -> some View {
        let ms = Int(seconds * 1000)
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "#fafaf9").opacity(0.4))
            Text("\(ms)ms")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(hex: "#fbbf24").opacity(0.7))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(hex: "#fafaf9").opacity(0.04))
        )
    }
}

#Preview {
    DictationView(viewModel: DictationViewModel())
}
