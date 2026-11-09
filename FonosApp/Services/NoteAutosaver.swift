import Foundation
import os.log

private let autosaveLog = Logger(subsystem: "com.fonos.ios", category: "NoteAutosaver")

/// Keeps an open note on disk while it is edited, and decides what Done and
/// Cancel leave behind once the autosaves have already changed the note.
@MainActor
final class NoteAutosaver {
    let originalText: String

    private let save: (String) throws -> Void
    private var savedText: String
    /// Set by Done and Cancel, so a tick during the sheet's closing animation
    /// cannot write over what they decided.
    private var isFinished = false

    init(originalText: String, save: @escaping (String) throws -> Void) {
        self.originalText = originalText
        self.savedText = originalText
        self.save = save
    }

    /// A failure is only logged: the next tick tries again, and Done reports it.
    /// Blank text is skipped because Done refuses to save a blank note.
    func autosave(_ text: String) {
        guard !isFinished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try write(text)
        } catch {
            autosaveLog.error("Autosave failed: \(error.localizedDescription)")
        }
    }

    /// Done: the note ends up with exactly `text`.
    func commit(_ text: String) throws {
        try write(text)
        isFinished = true
    }

    /// Cancel: the note goes back to the text it opened with.
    func revert() throws {
        try write(originalText)
        isFinished = true
    }

    private func write(_ text: String) throws {
        guard text != savedText else { return }
        try save(text)
        savedText = text
    }
}
