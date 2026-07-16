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

    /// Decode-only compatibility payload for pre-workflow releases. Runtime
    /// selection is `activeVoiceWorkflowID`.
    var activeModeID: String = "raw"

    /// Decode-only compatibility payload. Migration bakes this value into the
    /// Translate workflow widget.
    var translateTargetLanguage: String = "English"

    /// Decode-only compatibility payload for schema 0-2.
    var modes: [Mode] = Mode.builtInModes

    /// Decode-only compatibility payload for schema 0-2.
    var modeConfigs: [ModeConfig] = ModeConfig.builtInConfigs

    // MARK: - Workflows

    /// Version of the legacy ModeConfig → workflow compatibility migration.
    /// A zero value means the config predates the workflow model.
    var workflowSchemaVersion: Int = 0

    /// Desktop-compatible widget overlays. Builtins live in WorkflowCatalog.
    var widgets: [WorkflowWidget] = []

    /// Desktop-compatible workflow overlays.
    var workflows: [WorkflowDefinition] = []

    /// Selected voice recipe for the main app.
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

    /// Builtins with this config's desktop-compatible overlays applied.
    var workflowCatalog: WorkflowCatalog {
        .effective(userWidgets: widgets, userWorkflows: workflows)
    }

    var activeVoiceWorkflow: WorkflowDefinition? {
        workflowCatalog.workflow(id: activeVoiceWorkflowID)
    }

    /// Removes a model and every workflow/default reference to it.
    mutating func removeModelProfile(id: String) {
        modelProfiles.removeAll(where: { $0.id == id })
        if sttProfile == id { sttProfile = "" }
        if llmProfile == id { llmProfile = "" }
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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sttProvider, forKey: .sttProvider)
        try container.encode(sttProfile, forKey: .sttProfile)
        try container.encode(sttLanguage, forKey: .sttLanguage)
        try container.encode(llmProvider, forKey: .llmProvider)
        try container.encode(llmProfile, forKey: .llmProfile)
        try container.encode(llmBaseURL, forKey: .llmBaseURL)
        try container.encode(workflowSchemaVersion, forKey: .workflowSchemaVersion)
        try container.encode(widgets, forKey: .widgets)
        try container.encode(workflows, forKey: .workflows)
        try container.encode(activeVoiceWorkflowID, forKey: .activeVoiceWorkflowID)
        try container.encode(modelProfiles, forKey: .modelProfiles)
        try container.encode(recordMode, forKey: .recordMode)
        try container.encode(autoSendDestination, forKey: .autoSendDestination)
        try container.encode(destinations, forKey: .destinations)
        try container.encode(historyRetentionDays, forKey: .historyRetentionDays)

        // A pre-migration value can still be serialized by migration tests and
        // recovery tooling. Once schema 3 is reached, legacy Mode payloads are
        // intentionally retired from persisted AppConfig JSON.
        if workflowSchemaVersion < 3 {
            try container.encode(activeModeID, forKey: .activeModeID)
            try container.encode(translateTargetLanguage, forKey: .translateTargetLanguage)
            try container.encode(modes, forKey: .modes)
            try container.encode(modeConfigs, forKey: .modeConfigs)
        }
    }
}
