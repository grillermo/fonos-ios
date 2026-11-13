import Foundation

// Copied from DictusApp/DictusApp.swift (Dictus v2.0.0): the two names the
// vendored ModelManager posts and observes.
extension Notification.Name {
    static let dictusModelLoadStateChanged = Notification.Name("DictusModelLoadStateChanged")
    static let dictusModelPreparationChanged = Notification.Name("DictusModelPreparationChanged")
}
