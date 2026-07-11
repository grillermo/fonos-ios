import Foundation

/// How the user triggers recording.
enum RecordMode: String, Codable, Equatable, Hashable, Sendable {
    case tap
    case hold
}

/// Application-level configuration. Persisted via Codable → UserDefaults.
/// API keys are NOT stored here — they live in the Keychain only.
struct AppConfig: Codable, Equatable {
    // MARK: - STT

    var sttProvider: String = "apple"     // Legacy: keep for backward compat
    var sttProfile: String = ""           // Default STT model profile ID
    var sttLanguage: String = "auto"

    // MARK: - LLM

    var llmProvider: String = "openai"    // Legacy: keep for backward compat
    var llmProfile: String = ""           // Default LLM model profile ID
    var llmBaseURL: String = ""

    // MARK: - Modes

    /// Active mode identifier (matches ModeConfig.id or Mode.id).
    var activeModeID: String = "raw"

    /// Target language for Translate mode.
    var translateTargetLanguage: String = "English"

    /// Legacy modes array — kept for Codable backward compat and existing tests.
    var modes: [Mode] = Mode.builtInModes

    /// Mode configurations with per-mode model overrides and settings.
    var modeConfigs: [ModeConfig] = ModeConfig.builtInConfigs

    // MARK: - Models

    var modelProfiles: [ModelProfile] = []

    // MARK: - Recording

    var recordMode: RecordMode = .tap
    var autoSendDestination: String = ""

    // MARK: - Destinations

    var destinations: [AnyTextDestination] = [AnyTextDestination(ClipboardDestination())]

    // MARK: - History

    var historyRetentionDays: Int = 30

    // MARK: - Convenience

    /// The active mode derived from `modeConfigs`, falling back to the first mode in `modes`.
    var defaultMode: Mode {
        if let config = modeConfigs.first(where: { $0.id == activeModeID }) {
            return config.mode
        }
        return modes.first ?? .raw
    }

    /// The active ModeConfig, or nil if not found.
    var activeModeConfig: ModeConfig? {
        modeConfigs.first(where: { $0.id == activeModeID })
    }

    /// Resolves a mode-level STT profile override against the app default.
    /// Empty imported overrides are treated as unset.
    func effectiveSTTProfileID(forModeID modeID: String? = nil) -> String {
        let resolvedModeID = modeID ?? activeModeID
        if let override = modeConfigs
            .first(where: { $0.id == resolvedModeID })?
            .sttModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           modelProfiles.contains(where: { $0.id == override && $0.hasSTT }) {
            return override
        }
        return sttProfile
    }

    /// Resolves a mode-level LLM profile override against the app default.
    /// Empty imported overrides are treated as unset.
    func effectiveLLMProfileID(forModeID modeID: String? = nil) -> String {
        let resolvedModeID = modeID ?? activeModeID
        if let override = modeConfigs
            .first(where: { $0.id == resolvedModeID })?
            .llmModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           modelProfiles.contains(where: { $0.id == override && $0.hasLLM }) {
            return override
        }
        return llmProfile
    }

    /// Removes a model and every default/override reference to it so modes
    /// cleanly fall back to the remaining app defaults.
    mutating func removeModelProfile(id: String) {
        modelProfiles.removeAll(where: { $0.id == id })
        if sttProfile == id { sttProfile = "" }
        if llmProfile == id { llmProfile = "" }
        for index in modeConfigs.indices {
            if modeConfigs[index].sttModelID == id {
                modeConfigs[index].sttModelID = nil
            }
            if modeConfigs[index].llmModelID == id {
                modeConfigs[index].llmModelID = nil
            }
        }
    }
}
