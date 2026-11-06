import Foundation

/// What a failed retry means for auto-retry.
enum PendingRecordingFailure: Equatable, Sendable {
    /// The server may come back: end the pass and wait for the timer.
    case temporary
    /// Retrying the same way won't help: leave the item for a manual Retry.
    case permanent
    /// Nothing was attempted: end the pass without recording anything.
    case busy
    /// The recording no longer exists: move on.
    case gone

    /// Unknown errors are temporary, so a recording never silently leaves
    /// auto-retry.
    static func classify(_ error: any Error) -> PendingRecordingFailure {
        if error is CancellationError { return .busy }
        if let both = error as? EndpointFailoverError {
            return classify(both.primary) == .permanent && classify(both.fallback) == .permanent
                ? .permanent
                : .temporary
        }
        if let pending = error as? PendingRecordingError {
            switch pending {
            case .notFound: return .gone
            case .alreadyRetrying, .dictationBusy: return .busy
            case .recipeUnavailable, .notebookUnavailable: return .permanent
            }
        }
        if let stt = error as? STTError {
            switch stt {
            case .http(let status, _):
                return status == 408 || status == 429 || status >= 500 ? .temporary : .permanent
            case .badRequest, .authenticationFailed, .consentRequired, .insecureEndpoint,
                 .m4aUnsupported, .profileUnavailable:
                return .permanent
            default:
                return .temporary
            }
        }
        return .temporary
    }
}
