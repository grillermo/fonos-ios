import Foundation

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
