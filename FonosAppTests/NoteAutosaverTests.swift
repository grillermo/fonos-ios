// An open note is written to disk while it is being appended to, so closing
// the app early loses at most the last second of text.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteAutosaverTests

import Testing
import Foundation
@testable import FonosApp

private struct SaveFailed: Error {}

@MainActor
private final class SaveLog {
    var saved: [String] = []
    var failing = false

    func save(_ text: String) throws {
        if failing { throw SaveFailed() }
        saved.append(text)
    }
}

@Suite("Note autosave")
@MainActor
struct NoteAutosaverTests {
    private func makeAutosaver(_ log: SaveLog, original: String = "one") -> NoteAutosaver {
        NoteAutosaver(originalText: original, save: { try log.save($0) })
    }

    @Test("changed text is saved")
    func savesChangedText() {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("one two")

        #expect(log.saved == ["one two"])
    }

    @Test("text that has not changed since the last save is not written again")
    func skipsUnchangedText() {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("one")
        autosaver.autosave("one two")
        autosaver.autosave("one two")

        #expect(log.saved == ["one two"])
    }

    @Test("blank text does not replace the note")
    func skipsBlankText() {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("  \n")

        #expect(log.saved.isEmpty)
    }

    @Test("a failed autosave is tried again on the next tick")
    func retriesAfterFailure() {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        log.failing = true
        autosaver.autosave("one two")
        log.failing = false
        autosaver.autosave("one two")

        #expect(log.saved == ["one two"])
    }

    @Test("cancel puts back the text the note opened with")
    func revertRestoresOriginal() throws {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("one two")
        try autosaver.revert()

        #expect(log.saved == ["one two", "one"])
    }

    @Test("cancel writes nothing when nothing was autosaved")
    func revertWithoutAutosaveWritesNothing() throws {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        try autosaver.revert()

        #expect(log.saved.isEmpty)
    }

    @Test("done saves the latest text")
    func commitSavesLatestText() throws {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("one two")
        try autosaver.commit("one two three")

        #expect(log.saved == ["one two", "one two three"])
    }

    @Test("done after undoing back to the opening text restores it")
    func commitAfterUndoingAutosavedEdit() throws {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("one two")
        try autosaver.commit("one")

        #expect(log.saved == ["one two", "one"])
    }

    @Test("a failed done reports the error and leaves the note open to edit")
    func commitFailureThrowsAndKeepsAutosaving() throws {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        log.failing = true
        #expect(throws: SaveFailed.self) { try autosaver.commit("one two") }
        log.failing = false
        autosaver.autosave("one two")

        #expect(log.saved == ["one two"])
    }

    @Test("a tick during the closing animation cannot undo a cancel")
    func noAutosaveAfterRevert() throws {
        let log = SaveLog()
        let autosaver = makeAutosaver(log)

        autosaver.autosave("one two")
        try autosaver.revert()
        autosaver.autosave("one two")

        #expect(log.saved == ["one two", "one"])
    }
}
