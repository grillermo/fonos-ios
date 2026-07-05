import Foundation

// MARK: - VocabRule

/// How a correction rule's `from` pattern is interpreted.
/// JSON values mirror fonos-core vocab.rs (`literal` | `regex`).
enum VocabRuleKind: String, Codable, Equatable, Hashable, Sendable {
    case literal
    case regex
}

/// A single find → replace correction applied to transcripts.
/// JSON shape mirrors fonos-core vocab.rs, including serde(default) tolerance
/// for missing keys so desktop-exported books decode unchanged.
struct VocabRule: Codable, Equatable, Hashable, Sendable {
    /// Text or pattern to find.
    var from: String
    /// Replacement text. For regex rules, capture groups (`$1`) work.
    var to: String
    /// Literal (default) or regex matching.
    var kind: VocabRuleKind
    /// Case-insensitive matching (default true).
    var caseInsensitive: Bool

    enum CodingKeys: String, CodingKey {
        case from, to, kind
        case caseInsensitive = "case_insensitive"
    }

    init(from: String = "", to: String = "",
         kind: VocabRuleKind = .literal, caseInsensitive: Bool = true) {
        self.from = from
        self.to = to
        self.kind = kind
        self.caseInsensitive = caseInsensitive
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        self.to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        self.kind = try c.decodeIfPresent(VocabRuleKind.self, forKey: .kind) ?? .literal
        self.caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? true
    }
}

// MARK: - VocabBook

/// A named vocabulary: domain terms plus correction rules.
/// Standalone entity referenced by id from mounts (global / mode / notebook).
struct VocabBook: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable identifier referenced from config / modes.
    var id: String
    /// Display name.
    var name: String
    /// Disabled books are ignored everywhere without being deleted.
    var enabled: Bool
    /// Correct spellings of domain terms (one entry per term).
    var terms: [String]
    /// Deterministic post-transcription corrections, applied in order.
    var rules: [VocabRule]

    init(id: String = "", name: String = "", enabled: Bool = true,
         terms: [String] = [], rules: [VocabRule] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.terms = terms
        self.rules = rules
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        self.rules = try c.decodeIfPresent([VocabRule].self, forKey: .rules) ?? []
    }
}

// MARK: - VocabApplier

/// Pure vocab pipeline logic — a port of fonos-core vocab.rs so behaviour
/// matches desktop exactly. One book feeds three stages: STT prompt biasing,
/// deterministic correction, and LLM glossary blocks.
enum VocabApplier {

    /// Character budget for STT prompts. Whisper truncates its prompt to
    /// ~224 tokens; this keeps the merged prompt safely inside that window.
    static let sttPromptBudgetChars = 600

    /// Resolve the effective books: `globalIDs` first, then `modeIDs`,
    /// order-preserving, deduplicated, disabled books skipped.
    static func effectiveBooks(books: [VocabBook],
                               globalIDs: [String],
                               modeIDs: [String]) -> [VocabBook] {
        var seen: Set<String> = []
        var out: [VocabBook] = []
        for id in globalIDs + modeIDs {
            guard seen.insert(id).inserted else { continue }
            if let book = books.first(where: { $0.id == id && $0.enabled }) {
                out.append(book)
            }
        }
        return out
    }

    /// All terms across `books`, trimmed, deduplicated, order preserving.
    static func collectTerms(_ books: [VocabBook]) -> [String] {
        var out: [String] = []
        for book in books {
            for term in book.terms {
                let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !out.contains(t) {
                    out.append(t)
                }
            }
        }
        return out
    }

    /// Apply every rule of every book to `text`, in book order then rule
    /// order. A rule that fails to compile (bad user regex) is skipped —
    /// corrections must never break transcription.
    static func applyRules(_ text: String, books: [VocabBook]) -> String {
        var out = text
        for book in books {
            for rule in book.rules where !rule.from.isEmpty {
                guard let re = compileRule(rule) else { continue }
                let range = NSRange(out.startIndex..., in: out)
                out = re.stringByReplacingMatches(
                    in: out, options: [], range: range, withTemplate: rule.to
                )
            }
        }
        return out
    }

    /// Build the regex for one rule. Literal rules are escaped and, when the
    /// pattern starts/ends with an ASCII word character, guarded with `\b`
    /// so "art" doesn't rewrite "start". CJK text has no word boundaries,
    /// so non-ASCII-word edges match as plain substrings.
    private static func compileRule(_ rule: VocabRule) -> NSRegularExpression? {
        let pattern: String
        switch rule.kind {
        case .regex:
            pattern = rule.from
        case .literal:
            func isASCIIWord(_ c: Character?) -> Bool {
                guard let ascii = c?.asciiValue else { return false }
                return (48...57).contains(ascii)      // 0-9
                    || (65...90).contains(ascii)      // A-Z
                    || (97...122).contains(ascii)     // a-z
                    || ascii == 95                    // _
            }
            let escaped = NSRegularExpression.escapedPattern(for: rule.from)
            let lead = isASCIIWord(rule.from.first) ? "\\b" : ""
            let trail = isASCIIWord(rule.from.last) ? "\\b" : ""
            pattern = lead + escaped + trail
        }
        var options: NSRegularExpression.Options = []
        if rule.caseInsensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// Merge vocabulary terms into an STT initial prompt. Keeps the `base`
    /// prompt intact and appends a glossary sentence with as many terms as
    /// fit in `budgetChars` (in effective-book order, so global books get
    /// priority).
    static func buildSTTPrompt(base: String,
                               terms: [String],
                               budgetChars: Int = sttPromptBudgetChars) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return base }
        let prefix = "Vocabulary: "
        var remaining = max(0, budgetChars - base.count - (prefix.count + 2))
        var kept: [String] = []
        for term in terms {
            let cost = term.count + 2 // ", " separator
            if cost > remaining { break }
            remaining -= cost
            kept.append(term)
        }
        guard !kept.isEmpty else { return base }
        let glossary = prefix + kept.joined(separator: ", ") + "."
        return base.isEmpty ? glossary : base + " " + glossary
    }

    /// Glossary block appended to LLM system prompts. Returns nil when there
    /// is nothing to add. Wording matches fonos-core so behaviour tuning on
    /// desktop carries over.
    static func buildGlossaryBlock(terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return "\n\nDomain vocabulary: \(terms.joined(separator: ", ")). "
            + "The transcript may render these as sound-alike mis-transcriptions "
            + "(including English terms heard as similar-sounding words in another "
            + "language, e.g. a Chinese homophone standing in for an English term). "
            + "When context indicates one of these terms was meant, restore the "
            + "exact spelling listed here."
    }
}
