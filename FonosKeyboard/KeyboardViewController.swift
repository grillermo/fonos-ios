import UIKit
import os.log

private let kbLog = Logger(subsystem: "com.fonos.ios.keyboard", category: "KeyboardVC")

final class KeyboardViewController: UIInputViewController {

    // MARK: - State

    private enum KeyboardState {
        case ready
        case recording
        case processing
        case error(String)
        case done
        case copied
    }

    private var keyboardState: KeyboardState = .ready {
        didSet { updateUI() }
    }

    private struct KeyboardModeOption {
        let id: String
        let title: String
        let symbolName: String
    }

    private struct MinimalConfig: Decodable {
        var activeModeID: String?
        var activeVoiceWorkflowID: String?
        var widgets: [MinimalWorkflowWidget]?
        var workflows: [MinimalWorkflow]?
    }

    private struct MinimalWorkflow: Decodable {
        var id: String
        var name: String
        var icon: String?
        var source: String
        var processors: [String]?
        var outputs: [String]
    }

    private struct MinimalWorkflowWidget: Decodable {
        var id: String
        var role: String
        var typeTag: String

        private enum CodingKeys: String, CodingKey {
            case id, role
            case typeTag = "type_tag"
        }
    }

    private struct MinimalWidgetDescriptor {
        let role: String
        let typeTag: String
    }

    private let appGroupID = KeyboardIPC.appGroupID
    private let configKey = KeyboardIPC.DefaultsKey.appConfig
    private let keyboardModeOverrideKey = KeyboardIPC.DefaultsKey.modeOverride
    private let keyboardWorkflowOverrideKey = KeyboardIPC.DefaultsKey.workflowOverride
    private let keyboardWorkflowManifestKey = KeyboardIPC.DefaultsKey.workflowManifest
    private var currentWorkflowID = "wf.dictation"
    private var hasRunnableWorkflow = true

    // MARK: - Services

    private let audioService = KeyboardAudioService()

    // MARK: - UI Elements

    private let containerView = UIView()
    private let modeButton = UIButton(type: .system)
    private let micButton = UIButton(type: .custom)
    private let processingIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let switchButton = UIButton(type: .system)

    // MARK: - Colors

    private let amberColor = UIColor(red: 0xfb/255, green: 0xbf/255, blue: 0x24/255, alpha: 1)
    private let redColor = UIColor(red: 0xef/255, green: 0x44/255, blue: 0x44/255, alpha: 1)
    private let greenColor = UIColor(red: 0x86/255, green: 0xef/255, blue: 0xac/255, alpha: 1)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        loadSelectedMode()
        setupUI()
        updateUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The main app may have repaired/imported recipes while this keyboard
        // controller stayed alive. Re-read its prevalidated manifest so a
        // previous No Recipe state and stale selections recover immediately.
        refreshModeButton()
        updateUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Switching keyboards can remove the extension without invoking our
        // dismiss button. Cleanup sends a session-scoped producer cancel while
        // recording/processing is still outstanding.
        audioService.cleanup()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .clear
        containerView.backgroundColor = .clear
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 140),
        ])

        // Mode button (left) — shows current mode and opens a mode menu.
        modeButton.setTitleColor(amberColor, for: .normal)
        modeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.showsMenuAsPrimaryAction = true
        containerView.addSubview(modeButton)

        // Mic button (center)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.layer.cornerRadius = 28
        micButton.clipsToBounds = true
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        containerView.addSubview(micButton)

        processingIndicator.color = .black
        processingIndicator.hidesWhenStopped = true
        processingIndicator.translatesAutoresizingMaskIntoConstraints = false
        micButton.addSubview(processingIndicator)

        // Status label (bottom, full width)
        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)

        // Switch keyboard button (right) — small, for switching keyboards
        let switchConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        switchButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: switchConfig), for: .normal)
        switchButton.tintColor = .tertiaryLabel
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        switchButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        containerView.addSubview(switchButton)

        // Layout
        let micSize: CGFloat = 56
        NSLayoutConstraint.activate([
            // Mode: top-left
            modeButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            modeButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),

            // Mic: center-top
            micButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            micButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            micButton.widthAnchor.constraint(equalToConstant: micSize),
            micButton.heightAnchor.constraint(equalToConstant: micSize),
            processingIndicator.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            processingIndicator.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),

            // Switch: top-right
            switchButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            switchButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),

            // Status: below mic
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 6),
        ])

        refreshModeButton()
    }

    // MARK: - UI Update

    private func updateUI() {
        let symConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        switch keyboardState {
        case .ready:
            modeButton.isEnabled = true
            stopProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: symConfig), for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Start dictation"
            statusLabel.text = "Tap to dictate"
            statusLabel.textColor = .secondaryLabel

        case .recording:
            modeButton.isEnabled = false
            stopProcessingAnimation()
            micButton.backgroundColor = redColor
            micButton.setImage(UIImage(systemName: "stop.fill", withConfiguration: symConfig), for: .normal)
            micButton.tintColor = .white
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Stop dictation"
            statusLabel.text = "Recording... tap to stop"
            statusLabel.textColor = redColor

        case .processing:
            modeButton.isEnabled = false
            startProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(nil, for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Cancel dictation processing"
            statusLabel.text = "Processing... tap to cancel"
            statusLabel.textColor = amberColor

        case .error(let msg):
            modeButton.isEnabled = true
            stopProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: symConfig), for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Start dictation"
            statusLabel.text = msg
            statusLabel.textColor = redColor

        case .done:
            modeButton.isEnabled = true
            stopProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: symConfig), for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Start dictation"
            statusLabel.text = "✓ Text inserted"
            statusLabel.textColor = greenColor

        case .copied:
            modeButton.isEnabled = true
            stopProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(UIImage(systemName: "doc.on.clipboard.fill", withConfiguration: symConfig), for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Dictation copied"
            statusLabel.text = "✓ Copied to clipboard"
            statusLabel.textColor = greenColor
        }
        if !hasRunnableWorkflow {
            modeButton.isEnabled = false
            micButton.isEnabled = false
            micButton.isUserInteractionEnabled = false
            statusLabel.text = String(localized: "No runnable voice recipe. Open Fonos Settings.")
            statusLabel.textColor = redColor
        }
    }

    private func startProcessingAnimation() {
        processingIndicator.startAnimating()
        guard micButton.layer.animation(forKey: "processingPulse") == nil else { return }

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.96
        pulse.toValue = 1.06
        pulse.duration = 0.55
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        micButton.layer.add(pulse, forKey: "processingPulse")
    }

    private func stopProcessingAnimation() {
        processingIndicator.stopAnimating()
        micButton.layer.removeAnimation(forKey: "processingPulse")
    }

    // MARK: - Actions

    @objc private func modeTapped() {
        refreshModeButton()
    }

    @objc private func dismissTapped() {
        audioService.cleanup()
        dismissKeyboard()
    }

    @objc private func micTapped() {
        switch keyboardState {
        case .ready, .error, .done, .copied:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing:
            audioService.cleanup()
            keyboardState = .ready
        }
    }

    // MARK: - Recording

    private func startRecording() {
        refreshModeButton()
        guard hasRunnableWorkflow, !currentWorkflowID.isEmpty else { return }
        guard hasFullAccess else {
            keyboardState = .error("Enable Full Access in Settings → Keyboards → Fonos")
            return
        }

        statusLabel.text = "Starting..."
        statusLabel.textColor = .secondaryLabel

        audioService.startRecording(
            onPartial: { [weak self] text in
                // Live partial results (from App Group → main app's Apple Speech)
                DispatchQueue.main.async {
                    guard let self,
                          case .recording = self.keyboardState else { return }
                    self.statusLabel.text = text.isEmpty ? "Listening..." : text
                    self.statusLabel.textColor = .label
                }
            },
            onStatus: { [weak self] status in
                // App Group result notification
                DispatchQueue.main.async {
                    guard let self,
                          let result = KeyboardIPC.consumerResult(from: status) else { return }
                    switch result {
                    case .insert(let text, let pressEnter):
                        if !text.isEmpty {
                            self.textDocumentProxy.insertText(text)
                            if pressEnter {
                                self.textDocumentProxy.insertText("\n")
                            }
                            kbLog.info("✅ Inserted: \(text.prefix(50))...")
                            self.keyboardState = .done
                            self.autoReset()
                        } else {
                            self.keyboardState = .error("No speech detected")
                        }
                        self.audioService.cleanup()
                    case .error(let message):
                        self.keyboardState = .error(message)
                        self.audioService.cleanup()
                    case .copied:
                        self.keyboardState = .copied
                        self.autoReset()
                        self.audioService.cleanup()
                    }
                }
            },
            completion: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.keyboardState = .error(error.localizedDescription)
                } else {
                    self.keyboardState = .recording
                    self.statusLabel.text = "Recording..."
                    self.statusLabel.textColor = self.redColor
                }
            }
        )
    }

    private func stopAndTranscribe() {
        audioService.stopRecording()

        keyboardState = .processing
        let processingSessionID = audioService.activeSessionID
        // Remote STT plus multiple processors can legitimately take tens of
        // seconds. Tie the safety timeout to this exact session so an old
        // closure can never cancel a newer run.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + KeyboardIPC.processingTimeout
        ) { [weak self] in
            guard let self,
                  let processingSessionID,
                  self.audioService.activeSessionID == processingSessionID,
                  case .processing = self.keyboardState else { return }
            self.keyboardState = .error("Timeout — check if Fonos app is open")
            self.audioService.cleanup()
        }
    }

    private func autoReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            switch self?.keyboardState {
            case .done, .copied: self?.keyboardState = .ready
            default: break
            }
        }
    }

    // MARK: - Config

    private func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private func loadSelectedMode() {
        if let workflowID = sharedDefaults()?.string(forKey: keyboardWorkflowOverrideKey),
           !workflowID.isEmpty {
            currentWorkflowID = workflowID
            return
        }
        if let legacy = sharedDefaults()?.string(forKey: keyboardModeOverrideKey), !legacy.isEmpty {
            currentWorkflowID = workflowID(forLegacyModeID: legacy)
            return
        }
        if let data = sharedDefaults()?.data(forKey: configKey),
           let config = try? JSONDecoder().decode(MinimalConfig.self, from: data) {
            if let workflowID = config.activeVoiceWorkflowID, !workflowID.isEmpty {
                currentWorkflowID = workflowID
            } else if let modeID = config.activeModeID, !modeID.isEmpty {
                currentWorkflowID = workflowID(forLegacyModeID: modeID)
            }
        }
    }

    private func refreshModeButton() {
        let options = readModeOptions()
        guard let selected = options.first(where: { $0.id == currentWorkflowID })
                ?? options.first else {
            hasRunnableWorkflow = false
            currentWorkflowID = ""
            sharedDefaults()?.removeObject(forKey: keyboardWorkflowOverrideKey)
            sharedDefaults()?.removeObject(forKey: keyboardModeOverrideKey)
            modeButton.setImage(UIImage(systemName: "exclamationmark.triangle"), for: .normal)
            modeButton.setTitle(" No Recipe", for: .normal)
            modeButton.menu = nil
            updateUI()
            return
        }
        hasRunnableWorkflow = true
        if selected.id != currentWorkflowID {
            currentWorkflowID = selected.id
            sharedDefaults()?.set(selected.id, forKey: keyboardWorkflowOverrideKey)
            if let legacy = legacyModeID(forWorkflowID: selected.id) {
                sharedDefaults()?.set(legacy, forKey: keyboardModeOverrideKey)
            }
        }
        let image = UIImage(systemName: selected.symbolName)
        modeButton.setImage(image, for: .normal)
        modeButton.setTitle(" \(selected.title)", for: .normal)
        modeButton.tintColor = amberColor

        let actions = options.map { option in
            UIAction(
                title: option.title,
                image: UIImage(systemName: option.symbolName),
                state: option.id == currentWorkflowID ? .on : .off
            ) { [weak self] _ in
                self?.selectMode(option)
            }
        }
        modeButton.menu = UIMenu(title: "", options: .singleSelection, children: actions)
    }

    private func selectMode(_ option: KeyboardModeOption) {
        switch keyboardState {
        case .ready, .error, .done, .copied: break
        case .recording, .processing: return
        }
        currentWorkflowID = option.id
        sharedDefaults()?.set(option.id, forKey: keyboardWorkflowOverrideKey)
        if let legacyModeID = legacyModeID(forWorkflowID: option.id) {
            // Older main-app builds only understand this key. Keep writing it
            // during the compatibility window while the workflow id remains
            // authoritative for new builds.
            sharedDefaults()?.set(legacyModeID, forKey: keyboardModeOverrideKey)
        } else {
            sharedDefaults()?.removeObject(forKey: keyboardModeOverrideKey)
        }
        refreshModeButton()
        statusLabel.text = "Tap to dictate"
        statusLabel.textColor = .secondaryLabel
    }

    private func readModeOptions() -> [KeyboardModeOption] {
        let builtins = [
            MinimalWorkflow(id: "wf.dictation", name: "Raw", icon: "waveform", source: "src.mic-hold", processors: ["stt.default"], outputs: ["out.insert"]),
            MinimalWorkflow(id: "wf.voice.polish", name: "Polish", icon: "sparkles", source: "src.mic-hold", processors: ["stt.default", "llm.polish"], outputs: ["out.insert"]),
            MinimalWorkflow(id: "wf.voice.formal", name: "Formal", icon: "briefcase", source: "src.mic-hold", processors: ["stt.default", "llm.formal"], outputs: ["out.insert"]),
            MinimalWorkflow(id: "wf.voice.translate", name: "Translate", icon: "globe", source: "src.mic-hold", processors: ["stt.default", "llm.translate"], outputs: ["out.insert"])
        ]
        let fallback = builtins.map {
            KeyboardModeOption(
                id: $0.id,
                title: $0.name,
                symbolName: symbolName($0.icon, workflowID: $0.id)
            )
        }

        // The main app publishes this after running the full workflow and
        // profile validator. Prefer it over the extension's legacy structural
        // decoder so every recipe shown here is one the background runner can
        // actually compile on this device.
        if let manifestData = sharedDefaults()?.data(forKey: keyboardWorkflowManifestKey),
           let manifest = try? JSONDecoder().decode(
               [KeyboardIPC.WorkflowManifestEntry].self,
               from: manifestData
           ) {
            return manifest.map {
                KeyboardModeOption(
                    id: $0.id,
                    title: $0.name,
                    symbolName: symbolName($0.icon, workflowID: $0.id)
                )
            }
        }

        guard let data = sharedDefaults()?.data(forKey: configKey),
              let config = try? JSONDecoder().decode(MinimalConfig.self, from: data) else {
            return fallback
        }

        var workflows = builtins
        for overlay in config.workflows ?? [] {
            if let index = workflows.firstIndex(where: { $0.id == overlay.id }) {
                workflows[index] = overlay
            } else {
                workflows.append(overlay)
            }
        }

        let widgetTypes = (config.widgets ?? []).reduce(into: [String: MinimalWidgetDescriptor]()) {
            $0[$1.id] = MinimalWidgetDescriptor(role: $1.role, typeTag: $1.typeTag)
        }
        let runnable = workflows.filter { workflow in
            isRunnable(workflow, widgetTypes: widgetTypes)
        }
        guard !runnable.isEmpty else { return fallback }

        return runnable.map {
            KeyboardModeOption(
                id: $0.id,
                title: $0.name,
                symbolName: symbolName($0.icon, workflowID: $0.id)
            )
        }
    }

    private func isRunnable(
        _ workflow: MinimalWorkflow,
        widgetTypes: [String: MinimalWidgetDescriptor]
    ) -> Bool {
        guard let source = descriptor(for: workflow.source, overrides: widgetTypes),
              source.role == "source",
              source.typeTag == "microphone" else {
            return false
        }
        var kind = "audio"
        for processorID in workflow.processors ?? [] {
            guard let processor = descriptor(for: processorID, overrides: widgetTypes),
                  processor.role == "processor" else { return false }
            switch processor.typeTag {
            case "stt" where kind == "audio": kind = "text"
            case "llm" where kind == "text": kind = "text"
            default: return false
            }
        }
        guard kind == "text", !workflow.outputs.isEmpty else { return false }
        return workflow.outputs.allSatisfy { id in
            guard let output = descriptor(for: id, overrides: widgetTypes),
                  output.role == "output" else { return false }
            return ["insert", "return_to_caller", "clipboard"].contains(output.typeTag)
        }
    }

    private func symbolName(_ icon: String?, workflowID: String) -> String {
        if let icon, UIImage(systemName: icon) != nil { return icon }
        switch workflowID {
        case "wf.dictation": return "waveform"
        case "wf.voice.polish": return "sparkles"
        case "wf.voice.formal": return "briefcase"
        case "wf.voice.translate": return "globe"
        default: return "slider.horizontal.3"
        }
    }

    private func descriptor(
        for widgetID: String,
        overrides: [String: MinimalWidgetDescriptor]
    ) -> MinimalWidgetDescriptor? {
        if let value = overrides[widgetID] { return value }
        switch widgetID {
        case "src.mic-hold", "src.mic-toggle":
            return MinimalWidgetDescriptor(role: "source", typeTag: "microphone")
        case "stt.default":
            return MinimalWidgetDescriptor(role: "processor", typeTag: "stt")
        case "llm.polish", "llm.formal", "llm.translate":
            return MinimalWidgetDescriptor(role: "processor", typeTag: "llm")
        case "out.insert":
            return MinimalWidgetDescriptor(role: "output", typeTag: "insert")
        case "out.return":
            return MinimalWidgetDescriptor(role: "output", typeTag: "return_to_caller")
        case "out.clipboard":
            return MinimalWidgetDescriptor(role: "output", typeTag: "clipboard")
        default:
            return nil
        }
    }

    private func workflowID(forLegacyModeID modeID: String) -> String {
        switch modeID {
        case "raw": return "wf.dictation"
        case "polish", "formal", "translate": return "wf.voice.\(modeID)"
        default: return modeID.hasPrefix("wf.") ? modeID : "wf.custom-\(modeID)"
        }
    }

    private func legacyModeID(forWorkflowID workflowID: String) -> String? {
        switch workflowID {
        case "wf.dictation": return "raw"
        case "wf.voice.polish": return "polish"
        case "wf.voice.formal": return "formal"
        case "wf.voice.translate": return "translate"
        default:
            return workflowID.hasPrefix("wf.custom-")
                ? String(workflowID.dropFirst("wf.custom-".count))
                : nil
        }
    }
}
