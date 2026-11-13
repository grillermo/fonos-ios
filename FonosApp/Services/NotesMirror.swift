import Foundation

/// The file operations `NotesMirror` needs. The iCloud adapter swaps in
/// coordinated versions; tests use the plain one against a temp directory.
protocol MirrorFileSystem: Sendable {
    /// Whether something exists at the URL, even if it can't be read.
    func exists(_ url: URL) -> Bool
    /// The file's bytes, or nil when it does not exist or can't be read.
    func contents(of url: URL) -> Data?
    /// Writes atomically, creating the parent directory when needed.
    func write(_ data: Data, to url: URL) throws
    /// Removes the file; a file that is already gone is not an error.
    func remove(_ url: URL) throws
}

struct PlainMirrorFileSystem: MirrorFileSystem {
    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func contents(of url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

/// One-way mirror of notebooks into a folder: one `<title>.md` per notebook.
///
/// The phone is the source of truth. Files whose bytes already match are left
/// alone. Files for renamed or deleted notebooks are removed, but only files
/// this mirror wrote, as recorded in a hidden manifest. Anything else in the
/// folder is never touched.
struct NotesMirror: Sendable {
    struct Notebook: Sendable, Equatable {
        let id: UUID
        /// Filesystem-safe title without extension (`NoteService.sanitizedFilename`).
        let baseName: String
        let createdAt: Date
        let markdown: String
    }

    struct Result: Sendable, Equatable {
        var written = 0
        var deleted = 0
        var unchanged = 0
        var failed = 0
    }

    static let manifestName = ".fonos-mirror.json"
    static let pendingDeletePrefix = "pending-delete:"

    let root: URL
    let fileSystem: any MirrorFileSystem

    init(root: URL, fileSystem: any MirrorFileSystem = PlainMirrorFileSystem()) {
        self.root = root
        self.fileSystem = fileSystem
    }

    /// Assigns each notebook a filename, oldest first, so a later notebook with
    /// the same (case-insensitive) title gets `<name> (2).md` and keeps it.
    /// `isTaken` reports names that are unavailable for other reasons, such as
    /// an existing file this mirror does not own.
    static func assignFilenames(
        _ notebooks: [Notebook],
        isTaken: (String) -> Bool = { _ in false }
    ) -> [UUID: String] {
        let ordered = notebooks.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        var taken = Set<String>()
        var names: [UUID: String] = [:]
        for notebook in ordered {
            var name = "\(notebook.baseName).md"
            var suffix = 2
            while taken.contains(name.lowercased()) || isTaken(name) {
                name = "\(notebook.baseName) (\(suffix)).md"
                suffix += 1
            }
            taken.insert(name.lowercased())
            names[notebook.id] = name
        }
        return names
    }

    @discardableResult
    func sync(_ notebooks: [Notebook]) -> Result {
        var result = Result()
        // A manifest that exists but can't be read is a transient failure; going
        // on with an empty one would orphan every file this mirror owns.
        if fileSystem.exists(manifestURL), fileSystem.contents(of: manifestURL) == nil {
            result.failed = notebooks.count
            return result
        }
        let previous = readManifest()
        let owned = Set(previous.values.map { $0.lowercased() })
        let assigned = Self.assignFilenames(notebooks) { name in
            !owned.contains(name.lowercased()) && fileSystem.exists(root.appendingPathComponent(name))
        }
        var manifest: [String: String] = [:]

        for notebook in notebooks {
            guard let name = assigned[notebook.id] else { continue }
            let key = notebook.id.uuidString
            let url = root.appendingPathComponent(name)
            let data = Data(notebook.markdown.utf8)
            if fileSystem.contents(of: url) == data {
                result.unchanged += 1
                manifest[key] = name
                continue
            }
            do {
                try fileSystem.write(data, to: url)
                result.written += 1
                manifest[key] = name
            } catch {
                result.failed += 1
                // Keep owning the old file so it is neither orphaned nor deleted.
                if let old = previous[key] { manifest[key] = old }
            }
        }

        let kept = Set(manifest.values.map { $0.lowercased() })
        for (_, name) in previous where !kept.contains(name.lowercased()) {
            guard Self.isSafeFilename(name) else { continue }
            do {
                try fileSystem.remove(root.appendingPathComponent(name))
                result.deleted += 1
            } catch {
                result.failed += 1
                // Keep ownership under a synthetic key so the next run retries.
                manifest["\(Self.pendingDeletePrefix)\(name)"] = name
            }
        }

        writeManifest(manifest)
        return result
    }

    /// A manifest may be corrupt or edited by hand; only plain `.md` names
    /// directly inside the root are ever deleted.
    static func isSafeFilename(_ name: String) -> Bool {
        !name.contains("/") && !name.hasPrefix(".") && name.lowercased().hasSuffix(".md")
    }

    private var manifestURL: URL { root.appendingPathComponent(Self.manifestName) }

    private func readManifest() -> [String: String] {
        guard let data = fileSystem.contents(of: manifestURL),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return manifest
    }

    private func writeManifest(_ manifest: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest),
              fileSystem.contents(of: manifestURL) != data
        else { return }
        try? fileSystem.write(data, to: manifestURL)
    }
}
