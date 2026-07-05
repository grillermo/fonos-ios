import Foundation

/// Persists vocab books and their mounts. Kept outside AppConfig so adding
/// vocab support can't break AppConfig's Codable backward compatibility, and
/// because books are standalone entities referenced by id (mirrors desktop).
///
/// Mount keys: `global`, `mode:<modeID>`, `notebook:<uuid>`. The effective
/// set for a dictation/note is global ∪ scope, order-preserving, deduplicated
/// (see VocabApplier.effectiveBooks).
final class VocabStore: @unchecked Sendable {

    static let globalMountKey = "global"

    /// Book that accumulates rules captured from History corrections.
    static let correctionsBookID = "corrections"

    static func modeMountKey(_ modeID: String) -> String { "mode:\(modeID)" }
    static func notebookMountKey(_ id: UUID) -> String { "notebook:\(id.uuidString)" }

    // MARK: - Storage

    private struct State: Codable {
        var books: [VocabBook] = []
        var mounts: [String: [String]] = [:]
    }

    private let defaults: UserDefaults
    private let storageKey: String

    /// Read-through storage: every access decodes from UserDefaults so all
    /// VocabStore instances (view models, Settings, History) stay consistent.
    private var state: State {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode(State.self, from: data) else {
                return State()
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard, storageKey: String = "vocab_store_v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    // MARK: - Books

    var books: [VocabBook] { state.books }

    func book(id: String) -> VocabBook? {
        state.books.first { $0.id == id }
    }

    func upsert(_ book: VocabBook) {
        if let index = state.books.firstIndex(where: { $0.id == book.id }) {
            state.books[index] = book
        } else {
            state.books.append(book)
        }
    }

    func removeBook(id: String) {
        state.books.removeAll { $0.id == id }
        for (key, ids) in state.mounts {
            state.mounts[key] = ids.filter { $0 != id }
        }
    }

    // MARK: - Mounts

    func mountedIDs(forKey key: String) -> [String] {
        state.mounts[key] ?? []
    }

    /// Every mount (key → book ids). Used by Setup Doctor's config lint.
    func allMounts() -> [String: [String]] {
        state.mounts
    }

    func setMounted(_ ids: [String], forKey key: String) {
        state.mounts[key] = ids
    }

    func setMounted(_ mounted: Bool, bookID: String, forKey key: String) {
        var ids = mountedIDs(forKey: key)
        if mounted {
            if !ids.contains(bookID) { ids.append(bookID) }
        } else {
            ids.removeAll { $0 == bookID }
        }
        setMounted(ids, forKey: key)
    }

    // MARK: - Vocab context (shared STT pipeline helper)

    /// Everything a transcription path needs to apply a vocab: the resolved
    /// books, the STT bias terms, deterministic correction, and the LLM
    /// glossary. Built once per turn and reused by DictationViewModel,
    /// NoteViewModel, and the keyboard's BackgroundRecordingService so all
    /// three surfaces bias/correct identically.
    struct Context {
        let books: [VocabBook]
        let terms: [String]

        /// Apply the mounted correction rules to a transcript.
        func correct(_ text: String) -> String {
            VocabApplier.applyRules(text, books: books)
        }

        /// LLM glossary block (nil when there are no terms).
        var glossary: String? {
            VocabApplier.buildGlossaryBlock(terms: terms)
        }
    }

    /// Vocab context for a dictation in the given mode.
    func context(modeID: String?) -> Context {
        let books = effectiveBooks(modeID: modeID)
        return Context(books: books, terms: VocabApplier.collectTerms(books))
    }

    /// Vocab context for a voice note in the given notebook.
    func context(notebookID: UUID?) -> Context {
        let books = effectiveBooks(notebookID: notebookID)
        return Context(books: books, terms: VocabApplier.collectTerms(books))
    }

    // MARK: - Effective resolution

    /// Books for a dictation: global mounts plus the mode's mounts.
    func effectiveBooks(modeID: String?) -> [VocabBook] {
        VocabApplier.effectiveBooks(
            books: state.books,
            globalIDs: mountedIDs(forKey: Self.globalMountKey),
            modeIDs: modeID.map { mountedIDs(forKey: Self.modeMountKey($0)) } ?? []
        )
    }

    /// Books for a voice note: global mounts plus the notebook's mounts.
    func effectiveBooks(notebookID: UUID?) -> [VocabBook] {
        VocabApplier.effectiveBooks(
            books: state.books,
            globalIDs: mountedIDs(forKey: Self.globalMountKey),
            modeIDs: notebookID.map { mountedIDs(forKey: Self.notebookMountKey($0)) } ?? []
        )
    }

    // MARK: - Correction capture ("correction grows from use")

    /// Appends a correction rule to the Corrections book, creating and
    /// globally mounting it on first use.
    @discardableResult
    func addCorrectionRule(from: String, to: String,
                           kind: VocabRuleKind = .literal,
                           caseInsensitive: Bool = true) -> VocabBook {
        var corrections = book(id: Self.correctionsBookID)
            ?? VocabBook(id: Self.correctionsBookID, name: "Corrections")
        corrections.rules.append(
            VocabRule(from: from, to: to, kind: kind, caseInsensitive: caseInsensitive)
        )
        upsert(corrections)
        setMounted(true, bookID: Self.correctionsBookID, forKey: Self.globalMountKey)
        return corrections
    }

    /// Adds a domain term (correct spelling) to the Corrections book,
    /// creating and globally mounting it on first use.
    @discardableResult
    func addCorrectionTerm(_ term: String) -> VocabBook {
        var corrections = book(id: Self.correctionsBookID)
            ?? VocabBook(id: Self.correctionsBookID, name: "Corrections")
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !corrections.terms.contains(trimmed) {
            corrections.terms.append(trimmed)
        }
        upsert(corrections)
        setMounted(true, bookID: Self.correctionsBookID, forKey: Self.globalMountKey)
        return corrections
    }
}
