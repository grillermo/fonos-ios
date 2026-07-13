import SwiftUI

// MARK: - Pipeline preview

struct VoiceRecipePipelinePreview: View {
    let draft: VoiceRecipeDraft

    private let sourceColor = Color(hex: "#fbbf24")
    private let processorColor = Color(hex: "#86efac")
    private let outputColor = Color(red: 196 / 255, green: 181 / 255, blue: 253 / 255)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                node(draft.source.capture.shortLabel, icon: "mic.fill", color: sourceColor)
                arrow
                node(String(localized: "Transcribe"), icon: "text.bubble", color: processorColor)

                ForEach(draft.llms) { llm in
                    arrow
                    node(llm.previewName, icon: "sparkles", color: processorColor)
                }

                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(outputColor.opacity(0.75))
                    .padding(.horizontal, 1)

                VStack(alignment: .leading, spacing: 5) {
                    if draft.insertOutput.enabled {
                        node(String(localized: "Insert"), icon: "keyboard", color: outputColor)
                    }
                    if draft.clipboardOutput.enabled {
                        node(String(localized: "Clipboard"), icon: "doc.on.clipboard", color: outputColor)
                    }
                    if !draft.insertOutput.enabled && !draft.clipboardOutput.enabled {
                        node(String(localized: "No output"), icon: "exclamationmark.triangle", color: .red)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Recipe topology"))
        .accessibilityValue(accessibilitySummary)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(Color.white.opacity(0.28))
    }

    private func node(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }

    private var accessibilitySummary: String {
        var processors = ["Transcribe"] + draft.llms.map(\.previewName)
        if processors.isEmpty { processors = ["none"] }
        var outputs: [String] = []
        if draft.insertOutput.enabled { outputs.append("Insert") }
        if draft.clipboardOutput.enabled { outputs.append("Clipboard") }
        if outputs.isEmpty { outputs.append("none") }
        return "\(draft.source.capture.shortLabel), "
            + "then \(processors.joined(separator: ", then ")); "
            + "outputs: \(outputs.joined(separator: " and "))"
    }
}

// MARK: - STT editor

struct VoiceRecipeSTTEditor: View {
    @Binding var draft: VoiceRecipeSTTDraft
    let profiles: [ModelProfile]
    let vocabBooks: [VocabBook]
    let tint: Color
    let textPrimary: Color
    let textSecondary: Color

    private var missingProfile: String? {
        guard !draft.modelProfileID.isEmpty,
              draft.modelProfileID != ModelProfileReference.appleSpeech,
              !profiles.contains(where: { $0.id == draft.modelProfileID }) else { return nil }
        return draft.modelProfileID
    }

    private var hasKnownLanguage: Bool {
        draft.language == "auto" || SupportedLocale.all.contains(where: { $0.id == draft.language })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Model", selection: $draft.modelProfileID) {
                Text("Use default").tag("")
                Text("Apple Speech · On-device").tag(ModelProfileReference.appleSpeech)
                if let missingProfile {
                    Text("Missing · \(missingProfile)").tag(missingProfile)
                }
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .foregroundColor(textPrimary)

            Divider().overlay(Color.white.opacity(0.06))

            Picker("Language", selection: $draft.language) {
                Text("Auto-detect").tag("auto")
                if !hasKnownLanguage {
                    Text(draft.language).tag(draft.language)
                }
                ForEach(SupportedLocale.all) { locale in
                    Text(locale.displayName).tag(locale.id)
                }
            }
            .foregroundColor(textPrimary)

            Divider().overlay(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 7) {
                Text("Prompt hint")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(textSecondary)
                TextEditor(text: $draft.prompt)
                    .frame(minHeight: 66)
                    .padding(7)
                    .foregroundColor(textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.14)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Temperature")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(textSecondary)
                    Spacer()
                    Text(draft.temperature.formatted(.number.precision(.fractionLength(2))))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(tint)
                }
                Slider(value: $draft.temperature, in: 0...1, step: 0.05)
                    .tint(tint)
            }

            Divider().overlay(Color.white.opacity(0.06))

            VoiceRecipeVocabPicker(
                title: String(localized: "Recognition vocabulary"),
                detail: String(localized: "Terms bias recognition; rules correct the transcript before AI steps."),
                selectedIDs: $draft.vocabBookIDs,
                books: vocabBooks,
                tint: tint,
                textPrimary: textPrimary,
                textSecondary: textSecondary
            )
        }
        .padding(.vertical, 6)
    }
}

private struct VoiceRecipeVocabPicker: View {
    let title: String
    let detail: String
    @Binding var selectedIDs: [String]
    let books: [VocabBook]
    let tint: Color
    let textPrimary: Color
    let textSecondary: Color

    private var missingIDs: [String] {
        let known = Set(books.map(\.id))
        return selectedIDs.filter { !known.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(textSecondary)
                Spacer()
                Text(String(
                    format: String(localized: "%lld selected"),
                    Int64(selectedIDs.count)
                ))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(textSecondary)
            }

            Text(detail)
                .font(.caption2)
                .foregroundColor(textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if books.isEmpty && missingIDs.isEmpty {
                Text("No vocabulary books are available.")
                    .font(.caption)
                    .foregroundColor(textSecondary)
                    .padding(.vertical, 3)
            } else {
                ForEach(books) { book in
                    vocabButton(
                        id: book.id,
                        name: book.name,
                        detail: book.enabled ? nil : String(localized: "Disabled")
                    )
                }
                ForEach(missingIDs, id: \.self) { id in
                    vocabButton(
                        id: id,
                        name: id,
                        detail: String(localized: "Missing on this device")
                    )
                }
            }
        }
    }

    private func vocabButton(id: String, name: String, detail: String?) -> some View {
        let selected = selectedIDs.contains(id)
        return Button {
            if selected {
                selectedIDs.removeAll { $0 == id }
            } else {
                selectedIDs.append(id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundColor(selected ? tint : textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline)
                        .foregroundColor(textPrimary)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundColor(
                                detail == String(localized: "Missing on this device")
                                    ? .orange
                                    : textSecondary
                            )
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            selected ? String(localized: "Selected") : String(localized: "Not selected")
        )
    }
}

// MARK: - LLM editor

struct VoiceRecipeLLMEditorCard: View {
    private static let commonOutputLanguages = [
        "English", "Chinese", "Japanese", "Korean", "Spanish",
        "French", "German", "Portuguese", "Italian"
    ]

    @Binding var draft: VoiceRecipeLLMDraft
    let index: Int
    let count: Int
    @Binding var isExpanded: Bool
    let profiles: [ModelProfile]
    let vocabBooks: [VocabBook]
    let tint: Color
    let textPrimary: Color
    let textSecondary: Color
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    private var missingProfile: String? {
        guard !draft.modelProfileID.isEmpty,
              !profiles.contains(where: { $0.id == draft.modelProfileID }) else { return nil }
        return draft.modelProfileID
    }

    private var hasKnownOutputLanguage: Bool {
        draft.outputLanguage == "auto"
            || Self.commonOutputLanguages.contains(draft.outputLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .foregroundColor(tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1) · \(draft.previewName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(textPrimary)
                                .lineLimit(1)
                            Text(draft.failurePolicy == .useInput
                                 ? String(localized: "Uses input on failure")
                                 : String(localized: "Stops recipe on failure"))
                                .font(.caption2)
                                .foregroundColor(textSecondary)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                controlButton("arrow.up", disabled: index == 0, action: onMoveUp)
                controlButton("arrow.down", disabled: index == count - 1, action: onMoveDown)
                controlButton("trash", color: .red.opacity(0.82), action: onDelete)
            }

            if isExpanded {
                Divider().overlay(Color.white.opacity(0.06))

                labeledField(String(localized: "Step name")) {
                    TextField("AI transform", text: $draft.name)
                        .foregroundColor(textPrimary)
                        .textInputAutocapitalization(.sentences)
                }

                Picker("Model", selection: $draft.modelProfileID) {
                    Text("Use default").tag("")
                    if let missingProfile {
                        Text("Missing · \(missingProfile)").tag(missingProfile)
                    }
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .foregroundColor(textPrimary)

                Picker("Output language", selection: $draft.outputLanguage) {
                    Text("Auto · Keep input language").tag("auto")
                    if !hasKnownOutputLanguage {
                        Text(
                            draft.outputLanguage.isEmpty
                                ? "Empty value · Preserved"
                                : draft.outputLanguage
                        )
                        .tag(draft.outputLanguage)
                    }
                    ForEach(Self.commonOutputLanguages, id: \.self) { language in
                        Text(LocalizedStringKey(language)).tag(language)
                    }
                }
                .foregroundColor(textPrimary)

                labeledField(String(localized: "System instructions")) {
                    TextEditor(text: $draft.systemPrompt)
                        .frame(minHeight: 96)
                        .padding(7)
                        .foregroundColor(textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.14)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                }

                labeledField(String(localized: "User template")) {
                    TextEditor(text: $draft.userTemplate)
                        .frame(minHeight: 82)
                        .padding(7)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.14)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(
                                    draft.userTemplate.contains("{text}")
                                        ? Color.white.opacity(0.06)
                                        : Color.orange.opacity(0.55),
                                    lineWidth: 1
                                )
                        )
                }

                if !draft.userTemplate.contains("{text}") {
                    Label(
                        "No {text}: this is a valid fixed prompt and will ignore the previous step's text.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Temperature")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(textSecondary)
                        Spacer()
                        Text(draft.temperature.formatted(.number.precision(.fractionLength(2))))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(tint)
                    }
                    Slider(value: $draft.temperature, in: 0...2, step: 0.05)
                        .tint(tint)
                }

                Stepper(value: $draft.maxTokens, in: 1...128_000, step: 256) {
                    HStack {
                        Text("Max tokens")
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text("\(draft.maxTokens)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(textSecondary)
                    }
                }

                Picker("If this step fails", selection: $draft.failurePolicy) {
                    ForEach(VoiceRecipeFailurePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .foregroundColor(textPrimary)

                Divider().overlay(Color.white.opacity(0.06))

                VoiceRecipeVocabPicker(
                    title: String(localized: "LLM glossary"),
                    detail: String(localized: "Terms from these books are appended as glossary context for this processor."),
                    selectedIDs: $draft.vocabBookIDs,
                    books: vocabBooks,
                    tint: tint,
                    textPrimary: textPrimary,
                    textSecondary: textSecondary
                )
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(textSecondary)
            content()
        }
    }

    private func controlButton(
        _ icon: String,
        color: Color? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(color ?? textSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.035)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.25 : 1)
    }
}
