import UIKit
import AVFoundation
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
        var modeConfigs: [MinimalModeConfig]?
    }

    private struct MinimalModeConfig: Decodable {
        var id: String
        var name: String
        var icon: String?
    }

    private let appGroupID = "group.com.fonos.ios"
    private let configKey = "app_config"
    private let keyboardModeOverrideKey = "kb_active_mode_id"
    private var currentModeID = "raw"

    // MARK: - Services

    private let audioService = KeyboardAudioService()
    private let sttService = KeyboardSTTService()

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
        setupUI()
        loadSelectedMode()
        updateUI()

        // Pre-request mic permission on load so dialog appears early
        if hasFullAccess {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    kbLog.info("🔑 KB mic request result: \(granted)")
                    if !granted {
                        self?.keyboardState = .error("Mic denied — enable in Settings → Privacy → Microphone")
                    }
                }
            }
        }
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
            startProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(nil, for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = false
            micButton.accessibilityLabel = "Processing dictation"
            statusLabel.text = "Processing"
            statusLabel.textColor = amberColor

        case .error(let msg):
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
            stopProcessingAnimation()
            micButton.backgroundColor = amberColor
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: symConfig), for: .normal)
            micButton.tintColor = .black
            micButton.isEnabled = true
            micButton.isUserInteractionEnabled = true
            micButton.accessibilityLabel = "Start dictation"
            statusLabel.text = "✓ Text inserted"
            statusLabel.textColor = greenColor
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
        dismissKeyboard()
    }

    @objc private func micTapped() {
        switch keyboardState {
        case .ready, .error, .done:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
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
                    guard let self else { return }
                    if status.hasPrefix("done:") {
                        let text = String(status.dropFirst(5))
                        if !text.isEmpty {
                            self.textDocumentProxy.insertText(text)
                            kbLog.info("✅ Inserted: \(text.prefix(50))...")
                            self.keyboardState = .done
                            self.autoReset()
                        } else {
                            self.keyboardState = .error("No speech detected")
                        }
                        self.audioService.cleanup()
                    } else if status.hasPrefix("error:") {
                        let err = String(status.dropFirst(6))
                        self.keyboardState = .error(err)
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
        let strategy = audioService.activeStrategy
        audioService.stopRecording()

        if strategy == .direct {
            // Direct recording: transcribe locally
            keyboardState = .processing

            audioService.transcribeDirectRecording(language: nil) { [weak self] text, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let text, !text.isEmpty {
                        self.textDocumentProxy.insertText(text)
                        kbLog.info("✅ Inserted: \(text.prefix(50))...")
                        self.keyboardState = .done
                        self.autoReset()
                    } else {
                        self.keyboardState = .error(error?.localizedDescription ?? "No speech")
                    }
                    self.audioService.cleanup()
                }
            }
        } else {
            // App Group: main app is processing, show status
            keyboardState = .processing
            // Result comes via onStatus callback — add timeout as safety
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                if case .processing = self.keyboardState {
                    self.keyboardState = .error("Timeout — check if Fonos app is open")
                    self.audioService.cleanup()
                }
            }
        }
    }

    private func autoReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if case .done = self?.keyboardState { self?.keyboardState = .ready }
        }
    }

    // MARK: - Config

    private var isFullAccessEnabled: Bool {
        hasFullAccess
    }

    private func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private func loadSelectedMode() {
        if let modeID = sharedDefaults()?.string(forKey: keyboardModeOverrideKey), !modeID.isEmpty {
            currentModeID = modeID
            return
        }
        if let data = sharedDefaults()?.data(forKey: configKey) ?? UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(MinimalConfig.self, from: data),
           let modeID = config.activeModeID,
           !modeID.isEmpty {
            currentModeID = modeID
        }
    }

    private func refreshModeButton() {
        let options = readModeOptions()
        let selected = options.first { $0.id == currentModeID } ?? options[0]
        let image = UIImage(systemName: selected.symbolName)
        modeButton.setImage(image, for: .normal)
        modeButton.setTitle(" \(selected.title)", for: .normal)
        modeButton.tintColor = amberColor

        let actions = options.map { option in
            UIAction(
                title: option.title,
                image: UIImage(systemName: option.symbolName),
                state: option.id == currentModeID ? .on : .off
            ) { [weak self] _ in
                self?.selectMode(option)
            }
        }
        modeButton.menu = UIMenu(title: "", options: .singleSelection, children: actions)
    }

    private func selectMode(_ option: KeyboardModeOption) {
        currentModeID = option.id
        sharedDefaults()?.set(option.id, forKey: keyboardModeOverrideKey)
        refreshModeButton()
        statusLabel.text = "Tap to dictate"
        statusLabel.textColor = .secondaryLabel
    }

    private func readModeOptions() -> [KeyboardModeOption] {
        let fallback = [
            KeyboardModeOption(id: "raw", title: "Raw", symbolName: "waveform"),
            KeyboardModeOption(id: "polish", title: "Polish", symbolName: "sparkles"),
            KeyboardModeOption(id: "formal", title: "Formal", symbolName: "briefcase"),
            KeyboardModeOption(id: "translate", title: "Translate", symbolName: "globe")
        ]

        guard let data = sharedDefaults()?.data(forKey: configKey) ?? UserDefaults.standard.data(forKey: configKey),
              let config = try? JSONDecoder().decode(MinimalConfig.self, from: data),
              let modes = config.modeConfigs,
              !modes.isEmpty else {
            return fallback
        }

        return modes.map {
            KeyboardModeOption(
                id: $0.id,
                title: $0.name,
                symbolName: $0.icon ?? fallbackSymbol(for: $0.id)
            )
        }
    }

    private func fallbackSymbol(for modeID: String) -> String {
        switch modeID {
        case "raw": return "waveform"
        case "polish": return "sparkles"
        case "formal": return "briefcase"
        case "translate": return "globe"
        default: return "slider.horizontal.3"
        }
    }
}
