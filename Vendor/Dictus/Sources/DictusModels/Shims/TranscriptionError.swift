import Foundation
import DictusCore

// Copied verbatim from DictusApp/Audio/TranscriptionService.swift (Dictus v2.0.0).
enum TranscriptionError: Error, DiagnosableError {
    case notReady

    /// The recording held no samples at all.
    case emptyAudio

    /// The engine ran and produced nothing usable: an empty result, or audio it refused
    /// as too short to contain speech.
    ///
    /// WHY it is separate from `transcriptionFailed` (#313, 2026-08-25): this is a
    /// **notice**, not a fault. Nothing is wrong with the app — the user stopped a beat
    /// too early, or spoke into a silent room, or the model heard nothing it could turn
    /// into words. The `context` is diagnostic only; every case says the same sentence.
    case noSpeechDetected(context: String)

    /// The engine failed for a reason of its own. The payload is the engine's English
    /// text and is diagnostic only.
    case transcriptionFailed(String)

    /// User-facing text. Written to `DictationErrorChannel` and displayed by whichever
    /// surface the user is on — the keyboard's toolbar, the app's failure screen, or both.
    var errorDescription: String? {
        switch self {
        case .notReady:
            return String(localized: "The transcription engine is not ready. Open Dictus and try again.",
                          comment: "Shown when a dictation reaches transcription with no engine initialized (issue #313).")
        case .emptyAudio, .noSpeechDetected:
            return DictationFailureMessage.noWordsDetected
        case .transcriptionFailed:
            return String(localized: "The transcription failed. Tap the microphone to try again.",
                          comment: "Shown when the transcription engine fails for a reason the app cannot name. Deliberately names no cause (issues #313, #320).")
        }
    }

    /// English technical detail for the log. Never shown to the user.
    var diagnosticDescription: String {
        switch self {
        case .notReady:
            return "transcription service is not ready — no engine initialized"
        case .emptyAudio:
            return "no audio samples to transcribe"
        case .noSpeechDetected(let context):
            return "no speech detected: \(context)"
        case .transcriptionFailed(let message):
            return "transcription failed: \(message)"
        }
    }
}
