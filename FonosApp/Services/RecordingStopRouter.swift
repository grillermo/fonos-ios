import ObjectiveC
import os
import UIKit

/// Knows how to stop whatever is recording right now, so Return on a hardware
/// keyboard can do it from any screen. View models register while they capture.
/// `DictationViewModel` isn't main-actor isolated, so registering is thread-safe.
final class RecordingStopRouter: Sendable {
    typealias Stop = @MainActor @Sendable () -> Void

    static let shared = RecordingStopRouter()

    private let stops = OSAllocatedUnfairLock<[ObjectIdentifier: Stop]>(initialState: [:])

    var hasActiveRecording: Bool { stops.withLock { !$0.isEmpty } }

    func isRegistered(_ owner: AnyObject) -> Bool {
        let id = ObjectIdentifier(owner)
        return stops.withLock { $0[id] != nil }
    }

    func register(_ owner: AnyObject, stop: @escaping Stop) {
        let id = ObjectIdentifier(owner)
        stops.withLock { $0[id] = stop }
    }

    func unregister(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        _ = stops.withLock { $0.removeValue(forKey: id) }
    }

    @MainActor
    func stop(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        stops.withLock { $0.removeValue(forKey: id) }?()
    }

    /// Stops every active recording, which then transcribes what it captured.
    @MainActor
    func stopAll() {
        let active = stops.withLock { current in
            defer { current.removeAll() }
            return Array(current.values)
        }
        active.forEach { $0() }
    }
}

/// Catches Return before the responder chain sees it. A `.keyboardShortcut`
/// only fires on the visible tab and loses to a focused text view; here one
/// check covers every tab, sheet and text field. With nothing recording,
/// Return is left alone.
@MainActor
enum ReturnKeyRecordingStop {
    private static var isConsumingReturn = false

    /// SwiftUI's `@main` always uses its own `UIApplication` subclass and
    /// ignores `NSPrincipalClass`, so `sendEvent` can't be overridden.
    static func install() {
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.fonos_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Consumes the whole press, so its key-up can't reach a text view that
    /// never saw the key-down.
    fileprivate static func consume(_ event: UIPressesEvent) -> Bool {
        guard let press = event.allPresses.first(where: isReturn) else { return false }

        switch press.phase {
        case .began:
            guard RecordingStopRouter.shared.hasActiveRecording,
                  press.key?.modifierFlags.subtracting([.numericPad, .alphaShift]).isEmpty == true
            else { return false }
            isConsumingReturn = true
            RecordingStopRouter.shared.stopAll()
            return true
        case .ended, .cancelled:
            defer { isConsumingReturn = false }
            return isConsumingReturn
        default:
            return isConsumingReturn
        }
    }

    private static func isReturn(_ press: UIPress) -> Bool {
        press.key?.keyCode == .keyboardReturnOrEnter || press.key?.keyCode == .keypadEnter
    }
}

private extension UIApplication {
    /// After `install()`, this name holds the original `sendEvent`.
    @objc func fonos_sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent, ReturnKeyRecordingStop.consume(presses) { return }
        fonos_sendEvent(event)
    }
}
