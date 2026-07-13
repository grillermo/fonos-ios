import Foundation
import SwiftData

/// Persisted record of a completed dictation session.
@Model
final class DictationSession {
    var id: UUID
    var date: Date
    /// Stable recipe identity. Unlike the legacy `mode` field this preserves
    /// custom workflow UUIDs and can be resolved back to the workflow catalog.
    var workflowID: String = ""
    /// Name frozen at run time so History remains meaningful after a recipe is
    /// renamed or removed.
    var workflowName: String = ""
    /// Legacy mode key retained for filtering/backward compatibility.
    var mode: String
    var inputText: String
    var outputText: String
    var destination: String
    var latencyMs: Double

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        workflowID: String = "",
        workflowName: String = "",
        mode: String = "raw",
        inputText: String = "",
        outputText: String = "",
        destination: String = "clipboard",
        latencyMs: Double = 0
    ) {
        self.id = id
        self.date = date
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.mode = mode
        self.inputText = inputText
        self.outputText = outputText
        self.destination = destination
        self.latencyMs = latencyMs
    }
}

extension DictationSession {
    /// Flow outputs fan out, while the legacy persistence column is a string.
    /// Treat it as a comma-separated compatibility envelope until the next
    /// SwiftData schema version can store delivery attempts structurally.
    var destinationIDs: [String] {
        let values = destination
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? ["result"] : values
    }
}
