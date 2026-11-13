// One-way mirror of notebooks into a folder (iCloud Drive in the app):
// one Markdown file per notebook, unchanged files untouched, and only
// files the mirror wrote itself are ever deleted.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NotesMirrorTests

import Testing
import Foundation
@testable import FonosApp

@Suite("Notes mirror")
final class NotesMirrorTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesMirrorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Plain file system that can be told to fail removals or to report the
    /// manifest as unreadable.
    private struct FlakyFileSystem: MirrorFileSystem {
        var failRemoving: Set<String> = []
        var manifestUnreadable = false
        private let plain = PlainMirrorFileSystem()

        func exists(_ url: URL) -> Bool { plain.exists(url) }

        func contents(of url: URL) -> Data? {
            if manifestUnreadable, url.lastPathComponent == NotesMirror.manifestName { return nil }
            return plain.contents(of: url)
        }

        func write(_ data: Data, to url: URL) throws { try plain.write(data, to: url) }

        func remove(_ url: URL) throws {
            if failRemoving.contains(url.lastPathComponent) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try plain.remove(url)
        }
    }

    private var mirror: NotesMirror { NotesMirror(root: root) }

    private func notebook(
        _ title: String,
        id: UUID = UUID(),
        created: TimeInterval = 0,
        markdown: String? = nil
    ) -> NotesMirror.Notebook {
        NotesMirror.Notebook(
            id: id,
            baseName: title,
            createdAt: Date(timeIntervalSince1970: created),
            markdown: markdown ?? "# \(title)\n"
        )
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("writes one markdown file per notebook plus a manifest")
    func createsFiles() throws {
        let result = mirror.sync([
            notebook("Work", markdown: "# Work\nhello"),
            notebook("Ideas", created: 1),
        ])
        #expect(result == NotesMirror.Result(written: 2))
        #expect(try files() == [".fonos-mirror.json", "Ideas.md", "Work.md"])
        #expect(try text("Work.md") == "# Work\nhello")
    }

    @Test("an identical second run writes nothing")
    func unchangedIsSkipped() throws {
        let books = [notebook("Work")]
        mirror.sync(books)
        let result = mirror.sync(books)
        #expect(result == NotesMirror.Result(unchanged: 1))
    }

    @Test("changed content is rewritten")
    func changedIsRewritten() throws {
        let id = UUID()
        mirror.sync([notebook("Work", id: id, markdown: "one")])
        let result = mirror.sync([notebook("Work", id: id, markdown: "two")])
        #expect(result == NotesMirror.Result(written: 1))
        #expect(try text("Work.md") == "two")
    }

    @Test("renaming a notebook replaces its file")
    func renameReplacesFile() throws {
        let id = UUID()
        mirror.sync([notebook("Old", id: id)])
        let result = mirror.sync([notebook("New", id: id)])
        #expect(result == NotesMirror.Result(written: 1, deleted: 1))
        #expect(try files() == [".fonos-mirror.json", "New.md"])
    }

    @Test("deleting a notebook removes its file")
    func deleteRemovesFile() throws {
        mirror.sync([notebook("Work"), notebook("Ideas", created: 1)])
        let result = mirror.sync([notebook("Ideas", created: 1)])
        #expect(result.deleted == 1)
        #expect(try files() == [".fonos-mirror.json", "Ideas.md"])
    }

    @Test("same titles get numbered suffixes, stable across runs")
    func collisionsAreNumbered() throws {
        let first = notebook("Work", created: 0, markdown: "first")
        let second = notebook("work", created: 1, markdown: "second")
        mirror.sync([second, first])
        #expect(try files() == [".fonos-mirror.json", "Work.md", "work (2).md"])
        #expect(try text("Work.md") == "first")
        #expect(try text("work (2).md") == "second")
        #expect(mirror.sync([first, second]) == NotesMirror.Result(unchanged: 2))
    }

    @Test("files the mirror did not write are never touched")
    func foreignFilesSurvive() throws {
        try "mine".write(to: root.appendingPathComponent("Mine.md"), atomically: true, encoding: .utf8)
        mirror.sync([notebook("Work")])
        mirror.sync([])
        #expect(try files() == [".fonos-mirror.json", "Mine.md"])
        #expect(try text("Mine.md") == "mine")
    }

    @Test("a corrupt manifest is treated as empty")
    func corruptManifest() throws {
        try "not json".write(to: root.appendingPathComponent(".fonos-mirror.json"), atomically: true, encoding: .utf8)
        try "mine".write(to: root.appendingPathComponent("Mine.md"), atomically: true, encoding: .utf8)
        let result = mirror.sync([notebook("Work")])
        #expect(result == NotesMirror.Result(written: 1))
        #expect(try files() == [".fonos-mirror.json", "Mine.md", "Work.md"])
    }

    @Test("manifest entries pointing outside the folder are never deleted")
    func manifestCannotEscapeRoot() throws {
        let victimName = "victim-\(UUID().uuidString).md"
        let victim = root.deletingLastPathComponent().appendingPathComponent(victimName)
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: victim) }
        let manifest = #"{"\#(UUID().uuidString)":"../\#(victimName)"}"#
        try manifest.write(to: root.appendingPathComponent(".fonos-mirror.json"), atomically: true, encoding: .utf8)

        mirror.sync([])

        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("a delete that fails after a rename is retried on the next run")
    func failedDeleteIsRetried() throws {
        let id = UUID()
        mirror.sync([notebook("Old", id: id)])
        let flaky = NotesMirror(root: root, fileSystem: FlakyFileSystem(failRemoving: ["Old.md"]))
        let first = flaky.sync([notebook("New", id: id)])
        #expect(first == NotesMirror.Result(written: 1, failed: 1))
        #expect(try files() == [".fonos-mirror.json", "New.md", "Old.md"])

        let second = mirror.sync([notebook("New", id: id)])
        #expect(second.deleted == 1)
        #expect(try files() == [".fonos-mirror.json", "New.md"])
    }

    @Test("an existing file the mirror does not own is never overwritten")
    func foreignFileIsNotOverwritten() throws {
        try "mine".write(to: root.appendingPathComponent("Ideas.md"), atomically: true, encoding: .utf8)
        let result = mirror.sync([notebook("Ideas", markdown: "theirs")])
        #expect(result == NotesMirror.Result(written: 1))
        #expect(try text("Ideas.md") == "mine")
        #expect(try text("Ideas (2).md") == "theirs")
        mirror.sync([])
        #expect(try files() == [".fonos-mirror.json", "Ideas.md"])
    }

    @Test("an unreadable manifest aborts the sync without touching anything")
    func unreadableManifestAborts() throws {
        mirror.sync([notebook("Work", markdown: "one")])
        let manifestBefore = try text(NotesMirror.manifestName)

        let flaky = NotesMirror(root: root, fileSystem: FlakyFileSystem(manifestUnreadable: true))
        let result = flaky.sync([notebook("Work", markdown: "two"), notebook("Other", created: 1)])

        #expect(result == NotesMirror.Result(failed: 2))
        #expect(try files() == [".fonos-mirror.json", "Work.md"])
        #expect(try text("Work.md") == "one")
        #expect(try text(NotesMirror.manifestName) == manifestBefore)
    }
}
