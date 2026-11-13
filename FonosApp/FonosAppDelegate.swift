import DictusModels
import UIKit

/// UIKit hooks SwiftUI's `App` has no equivalent for: background download
/// events, and the lifecycle signals the termination watch records.
final class FonosAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let watch = TerminationWatch.shared
        UnexpectedExitNotice.shared.pending = watch.beginLaunch()
        watch.setInBackground(application.applicationState == .background)
        ExitMetricsReporter.shared.start()

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            watch.noteMemoryWarning()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            watch.setInBackground(true)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            watch.setInBackground(false)
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            watch.markCleanExit()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if !OnDeviceModels.handleBackgroundSessionEvents(
            identifier: identifier, completionHandler: completionHandler
        ) {
            completionHandler()
        }
    }
}
