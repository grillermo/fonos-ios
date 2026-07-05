import SwiftUI
import UniformTypeIdentifiers

/// Settings › Vocab — manage vocab books (P1-1). Books carry domain terms
/// (STT biasing + LLM glossary) and correction rules; JSON interchange
/// matches fonos-core vocab.rs so desktop books import unchanged.
struct VocabTab: View {

    private let store = VocabStore()

    @State private var books: [VocabBook] = []
    @State private var globalMounts: [String] = []
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                ForEach(books) { book in
                    NavigationLink {
                        VocabBookEditor(store: store, bookID: book.id, onChange: reload)
                    } label: {
                        bookRow(book)
                    }
                }
                .onDelete { indexSet in
                    indexSet.forEach { store.removeBook(id: books[$0].id) }
                    reload()
                }
            } header: {
                Text("Vocab Books")
            } footer: {
                Text("Terms bias speech recognition and LLM cleanup; rules apply deterministic corrections to every transcript. Globally mounted books apply everywhere.")
            }

            Section {
                Button {
                    let book = VocabBook(id: UUID().uuidString, name: "New Book")
                    store.upsert(book)
                    reload()
                } label: {
                    Label("New Book", systemImage: "plus")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import Book (JSON)", systemImage: "square.and.arrow.down")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: reload)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importBook(result)
        }
        .alert("Import failed", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func bookRow(_ book: VocabBook) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(book.name)
                    .font(.system(size: 15, weight: .medium))
                if !book.enabled {
                    Text("off")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if globalMounts.contains(book.id) {
                    Text("global")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#fbbf24"))
                }
            }
            Text("\(book.terms.count) terms · \(book.rules.count) rules")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func reload() {
        books = store.books
        globalMounts = store.mountedIDs(forKey: VocabStore.globalMountKey)
    }

    private func importBook(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            var book = try JSONDecoder().decode(VocabBook.self, from: data)
            if book.id.isEmpty { book.id = UUID().uuidString }
            if book.name.isEmpty { book.name = url.deletingPathExtension().lastPathComponent }
            store.upsert(book)
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - VocabBookEditor

private struct VocabBookEditor: View {
    let store: VocabStore
    let bookID: String
    var onChange: () -> Void

    @State private var book = VocabBook()
    @State private var isGlobal = false
    @State private var termsText = ""
    @State private var newRuleFrom = ""
    @State private var newRuleTo = ""
    @State private var newRuleRegex = false

    var body: some View {
        List {
            Section("Book") {
                TextField("Name", text: $book.name)
                Toggle("Enabled", isOn: $book.enabled)
                Toggle("Mount globally", isOn: $isGlobal)
            }

            Section {
                TextEditor(text: $termsText)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minHeight: 100)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Terms (one per line)")
            } footer: {
                Text("Correct spellings of domain terms, e.g. Kubernetes, fonos.")
            }

            Section("Correction Rules") {
                ForEach(Array(book.rules.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        Text(rule.from)
                            .font(.system(size: 13, design: .monospaced))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(rule.to)
                            .font(.system(size: 13, design: .monospaced))
                        Spacer()
                        if rule.kind == .regex {
                            Text("regex")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(hex: "#fbbf24"))
                        }
                    }
                }
                .onDelete { indexSet in
                    book.rules.remove(atOffsets: indexSet)
                }

                VStack(spacing: 8) {
                    TextField("Find (mis-heard text or pattern)", text: $newRuleFrom)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Replace with", text: $newRuleTo)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Regular expression", isOn: $newRuleRegex)
                    Button("Add Rule") {
                        book.rules.append(VocabRule(
                            from: newRuleFrom, to: newRuleTo,
                            kind: newRuleRegex ? .regex : .literal
                        ))
                        newRuleFrom = ""
                        newRuleTo = ""
                        newRuleRegex = false
                    }
                    .disabled(newRuleFrom.isEmpty || newRuleTo.isEmpty)
                }
            }

            Section {
                ShareLink(
                    item: exportText,
                    preview: SharePreview("\(book.name).json")
                ) {
                    Label("Export Book (JSON)", systemImage: "square.and.arrow.up")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(book.name.isEmpty ? "Book" : book.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private var exportText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(currentBook()) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func currentBook() -> VocabBook {
        var b = book
        b.terms = termsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return b
    }

    private func load() {
        book = store.book(id: bookID) ?? VocabBook(id: bookID, name: "Book")
        termsText = book.terms.joined(separator: "\n")
        isGlobal = store.mountedIDs(forKey: VocabStore.globalMountKey).contains(bookID)
    }

    private func save() {
        store.upsert(currentBook())
        store.setMounted(isGlobal, bookID: bookID, forKey: VocabStore.globalMountKey)
        onChange()
    }
}
