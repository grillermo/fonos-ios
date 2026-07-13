import Foundation

/// Compatibility seam for the older mode-oriented LLM API. Production
/// `LLMService` is adapted into `VoiceWorkflowLLMProvider` before compilation;
/// there is no independent execution path.
protocol LegacyModeLLMProvider: Sendable {
    func process(text: String, mode: Mode, glossary: String?) async throws -> String
}

extension LLMService: LegacyModeLLMProvider {}

/// Immutable vocabulary resolved while a canonical VoiceWorkflow plan is
/// compiled. Book order is significant: global books precede scoped books,
/// and deterministic rules run in that order.
struct VoiceWorkflowVocabulary: Equatable, Sendable {
    let effectiveBooks: [VocabBook]
    let terms: [String]

    init(effectiveBooks: [VocabBook]) {
        self.effectiveBooks = effectiveBooks
        self.terms = VocabApplier.collectTerms(effectiveBooks)
    }

    func correct(_ text: String) -> String {
        VocabApplier.applyRules(text, books: effectiveBooks)
    }

    var glossary: String? {
        VocabApplier.buildGlossaryBlock(terms: terms)
    }
}
