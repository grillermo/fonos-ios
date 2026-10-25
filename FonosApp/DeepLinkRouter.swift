import Foundation
import os

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the app receives a `fonos://record` deep link.
    static let fonosStartRecording = Notification.Name("com.fonos.ios.startRecording")

    /// Posted when the app receives a `fonos://note` deep link.
    static let fonosOpenNotes = Notification.Name("fonos.openNotes")

    /// Posted when the app receives a `fonos://config?d=…` deep link (a shared
    /// config bundle, e.g. from scanning a QR with the system Camera). userInfo
    /// carries the raw payload under "payload"; the receiver decodes + previews.
    /// `fonos://model?…` links (one model profile) travel the same way.
    static let fonosImportConfig = Notification.Name("com.fonos.ios.importConfig")
}

// MARK: - DeepLinkRouter

/// A single request to start foreground dictation.  The request identity lets
/// the UI acknowledge a notification without replaying the same URL when a
/// cold-started view later drains the router's pending queue.
struct DictationDeepLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let modeID: String?
    let destinationID: String?

    init(id: UUID = UUID(), modeID: String?, destinationID: String?) {
        self.id = id
        self.modeID = modeID
        self.destinationID = destinationID
    }
}

/// A one-shot request to open a notebook and present its recording sheet.
struct NoteRecordingDeepLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let notebookID: String?

    init(id: UUID = UUID(), notebookID: String?) {
        self.id = id
        self.notebookID = notebookID
    }
}

struct ConfigImportDeepLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let payload: String

    init(id: UUID = UUID(), payload: String) {
        self.id = id
        self.payload = payload
    }
}

/// Routes incoming `fonos://` deep links to the appropriate notification.
enum DeepLinkRouter {

    enum Request: Identifiable, Equatable, Sendable {
        case dictation(DictationDeepLinkRequest)
        case noteRecording(NoteRecordingDeepLinkRequest)
        case configImport(ConfigImportDeepLinkRequest)

        var id: UUID {
            switch self {
            case .dictation(let request): request.id
            case .noteRecording(let request): request.id
            case .configImport(let request): request.id
            }
        }
    }

    /// `onOpenURL` may run before ContentView has installed its notification
    /// subscriptions. Keep requests until the root view either acknowledges a
    /// live notification or drains them on appearance.
    private static let pendingRequests = OSAllocatedUnfairLock(initialState: [Request]())

    /// Handles an incoming URL, posting the appropriate notification for recognised schemes.
    @discardableResult
    static func handle(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == "fonos" else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        switch url.host?.lowercased() {
        case "record":
            let mode = components?.queryItems?.first(where: { $0.name == "mode" })?.value
            let destination = components?.queryItems?.first(where: { $0.name == "destination" })?.value
            let request = DictationDeepLinkRequest(
                modeID: nonEmpty(mode),
                destinationID: nonEmpty(destination)
            )
            let routed = Request.dictation(request)
            buffer(routed)
            var userInfo: [AnyHashable: Any] = ["request": request]
            if let modeID = request.modeID { userInfo["mode"] = modeID }
            if let destinationID = request.destinationID {
                userInfo["destination"] = destinationID
            }
            NotificationCenter.default.post(
                name: .fonosStartRecording,
                object: nil,
                userInfo: userInfo
            )
            return routed

        case "note":
            let notebookId = components?.queryItems?.first(where: { $0.name == "notebook" })?.value
            let request = NoteRecordingDeepLinkRequest(notebookID: nonEmpty(notebookId))
            let routed = Request.noteRecording(request)
            buffer(routed)
            var userInfo: [AnyHashable: Any] = ["request": request]
            if let notebookID = request.notebookID { userInfo["notebookId"] = notebookID }
            NotificationCenter.default.post(
                name: .fonosOpenNotes,
                object: nil,
                userInfo: userInfo
            )
            return routed

        case "config", "model":
            // Pass the whole URL through; the receiver decodes tolerantly and
            // shows a preview before applying anything.
            let request = ConfigImportDeepLinkRequest(payload: url.absoluteString)
            let routed = Request.configImport(request)
            buffer(routed)
            NotificationCenter.default.post(
                name: .fonosImportConfig,
                object: nil,
                userInfo: ["request": request, "payload": request.payload]
            )
            return routed

        default:
            return nil
        }
    }

    /// Removes a request handled through a live notification.
    static func acknowledge(_ id: UUID) {
        pendingRequests.withLock { requests in
            requests.removeAll(where: { $0.id == id })
        }
    }

    /// Atomically drains requests that arrived before the root UI subscribed.
    static func takePendingRequests() -> [Request] {
        pendingRequests.withLock { requests in
            let result = requests
            requests.removeAll(keepingCapacity: true)
            return result
        }
    }

    /// Stores a request until ContentView drains or acknowledges it. Internal
    /// visibility keeps the cold-start queue independently testable without
    /// posting a notification that the running test host would consume.
    static func buffer(_ request: Request) {
        pendingRequests.withLock { $0.append(request) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
