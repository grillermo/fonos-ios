import Foundation

/// A recording whose transcription run failed before any text was saved.
/// The audio sits beside this metadata in `PendingRecordingStore` until a
/// retry succeeds or the user discards it.
struct PendingRecording: Codable, Identifiable, Equatable, Sendable {
    enum Surface: String, Codable, Sendable {
        case dictate
        case note
    }

    /// Which list shows an item: History shows Dictate recordings, a
    /// notebook shows the notes recorded into it.
    enum Scope: Equatable, Sendable {
        case history
        case notebook(UUID)
    }

    let id: UUID
    let surface: Surface
    let workflowID: String?
    let notebookID: UUID?
    let createdAt: Date
    var lastError: String
    var attempts: Int
    let durationSeconds: TimeInterval
}

enum PendingRecordingError: LocalizedError, Equatable {
    case notFound
    case alreadyRetrying
    case dictationBusy
    case recipeUnavailable
    case notebookUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound:
            "This recording is no longer saved."
        case .alreadyRetrying:
            "This recording is already being retried."
        case .dictationBusy:
            "Finish the current dictation first."
        case .recipeUnavailable:
            "The recipe this recording used no longer exists. Discard it or record again."
        case .notebookUnavailable:
            "The notebook this recording belonged to no longer exists. Discard it or record again."
        }
    }
}
