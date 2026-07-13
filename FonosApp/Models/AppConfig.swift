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

    // MARK: - Workflows

    /// Version of the legacy ModeConfig → workflow compatibility migration.
    /// A zero value means the config predates the workflow model.
    var workflowSchemaVersion: Int = 0

    /// Desktop-compatible widget overlays. Builtins live in WorkflowCatalog.
    var widgets: [WorkflowWidget] = []

    /// Desktop-compatible workflow overlays. Legacy mode fields remain stored
    /// during the compatibility window and are not cleared by migration.
    var workflows: [WorkflowDefinition] = []

    /// Selected voice recipe. Kept separate from `activeModeID` so imported
    /// non-mode workflows can coexist without breaking keyboard compatibility.
    var activeVoiceWorkflowID: String = ""

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

    /// Builtins with this config's desktop-compatible overlays applied.
    var workflowCatalog: WorkflowCatalog {
        .effective(userWidgets: widgets, userWorkflows: workflows)
    }

    var activeVoiceWorkflow: WorkflowDefinition? {
        workflowCatalog.workflow(id: activeVoiceWorkflowID)
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
        return ModelProfileReference.normalized(sttProfile)
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
        return ModelProfileReference.normalized(llmProfile)
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
        for index in widgets.indices {
            guard case .object(var props) = widgets[index].props,
                  props["model_profile"]?.stringValue == id else { continue }
            props["model_profile"] = .string("")
            widgets[index].props = .object(props)
        }
    }
}

// A synthesized Codable initializer does not use stored-property defaults when
// a key is absent. Decode each field explicitly so configs written before the
// workflow slice keep every legacy setting and receive safe defaults for the
// additive fields.
extension AppConfig {
    private enum CodingKeys: String, CodingKey {
        case sttProvider, sttProfile, sttLanguage
        case llmProvider, llmProfile, llmBaseURL
        case activeModeID, translateTargetLanguage, modes, modeConfigs
        case workflowSchemaVersion, widgets, workflows, activeVoiceWorkflowID
        case modelProfiles, recordMode, autoSendDestination, destinations
        case historyRetentionDays
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sttProvider = try container.decodeIfPresent(String.self, forKey: .sttProvider) ?? sttProvider
        sttProfile = try container.decodeIfPresent(String.self, forKey: .sttProfile) ?? sttProfile
        sttLanguage = try container.decodeIfPresent(String.self, forKey: .sttLanguage) ?? sttLanguage
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider) ?? llmProvider
        llmProfile = try container.decodeIfPresent(String.self, forKey: .llmProfile) ?? llmProfile
        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? llmBaseURL
        activeModeID = try container.decodeIfPresent(String.self, forKey: .activeModeID) ?? activeModeID
        translateTargetLanguage = try container.decodeIfPresent(String.self, forKey: .translateTargetLanguage) ?? translateTargetLanguage
        modes = try container.decodeIfPresent([Mode].self, forKey: .modes) ?? modes
        modeConfigs = try container.decodeIfPresent([ModeConfig].self, forKey: .modeConfigs) ?? modeConfigs
        workflowSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .workflowSchemaVersion) ?? workflowSchemaVersion
        widgets = try container.decodeIfPresent([WorkflowWidget].self, forKey: .widgets) ?? widgets
        workflows = try container.decodeIfPresent([WorkflowDefinition].self, forKey: .workflows) ?? workflows
        activeVoiceWorkflowID = try container.decodeIfPresent(String.self, forKey: .activeVoiceWorkflowID) ?? activeVoiceWorkflowID
        modelProfiles = try container.decodeIfPresent([ModelProfile].self, forKey: .modelProfiles) ?? modelProfiles
        recordMode = try container.decodeIfPresent(RecordMode.self, forKey: .recordMode) ?? recordMode
        autoSendDestination = try container.decodeIfPresent(String.self, forKey: .autoSendDestination) ?? autoSendDestination
        destinations = try container.decodeIfPresent([AnyTextDestination].self, forKey: .destinations) ?? destinations
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? historyRetentionDays
    }
}
