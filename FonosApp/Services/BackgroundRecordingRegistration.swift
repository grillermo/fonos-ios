import UIKit
@preconcurrency import AVFoundation
import SwiftData
import os.log

extension BackgroundRecordingService {
    func register() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in register() }
            return
        }

        registrationLock.lock()
        guard !isRegistered else {
            registrationLock.unlock()
            backgroundRecordingLog.debug("BackgroundRecordingService already registered")
            return
        }
        isRegistered = true
        registrationLock.unlock()

        registerDarwinObservers()

        // Verify App Group
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            backgroundRecordingLog.info("✅ App Group: \(url.path)")
        } else {
            backgroundRecordingLog.error("❌ App Group NOT accessible!")
        }

        resetKeyboardIPCForNewAppInstance()
        deleteFile(KeyboardIPC.FileName.continuousAudio)
        deleteFile(KeyboardIPC.FileName.segmentAudio)
        publishReadiness(.inactive)

        // The heartbeat is deliberately withheld until the user explicitly
        // enables Keyboard Ready and the input graph is actually running.
        updateHeartbeat()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateHeartbeat()
        }

        registerSystemObservers()

        backgroundRecordingLog.info("✅ BackgroundRecordingService registered")
    }

    func registerDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<BackgroundRecordingService>.fromOpaque(obs).takeUnretainedValue().onStart()
        }, Self.kbStart, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<BackgroundRecordingService>.fromOpaque(obs).takeUnretainedValue().onStop()
        }, Self.kbStop, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<BackgroundRecordingService>.fromOpaque(obs).takeUnretainedValue().onCancel()
        }, Self.kbCancel, nil, .deliverImmediately)
    }

    func registerSystemObservers() {
        registerForegroundObserver()
        registerAudioInterruptionObserver()
        registerRouteChangeObserver()
        registerMediaServicesResetObserver()
        registerEngineConfigurationObserver()
    }

    func registerForegroundObserver() {
        // A valid ready session may recover its input graph when the containing
        // app returns to foreground after an interruption or route change.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.scheduleReadyEngineRecovery(after: 0)
        }
    }

    func registerAudioInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            if type == .began {
                backgroundRecordingLog.info("🎙 Keyboard Ready audio interrupted")
                self.handleReadyAudioLoss(.interruption, recoverAutomatically: false)
            } else if type == .ended {
                backgroundRecordingLog.info("🎙 Keyboard Ready interruption ended")
                self.scheduleReadyEngineRecovery(after: 0.15)
            }
        }
    }

    func registerRouteChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                  Self.routeChangeRequiresReadyEngineRebuild(reason) else { return }
            if Date() < self.suppressGraphChangesUntil, self.engine.isRunning { return }
            backgroundRecordingLog.info("🎙 Keyboard Ready route changed: \(rawReason)")
            self.handleReadyAudioLoss(.routeChange, recoverAutomatically: true)
        }
    }

    func registerMediaServicesResetObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            backgroundRecordingLog.warning("🎙 Keyboard Ready audio services reset")
            self.handleReadyAudioLoss(
                .mediaServicesReset,
                recoverAutomatically: true,
                recreateEngine: true
            )
        }
    }

    func registerEngineConfigurationObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let changedEngine = notification.object as? AVAudioEngine,
                  changedEngine === self.engine,
                  !self.isManagingReadyEngine else { return }
            if Date() < self.suppressGraphChangesUntil { return }
            backgroundRecordingLog.warning("🎙 Keyboard Ready engine configuration changed")
            self.handleReadyAudioLoss(
                .engineConfigurationChange,
                recoverAutomatically: true
            )
        }
    }

    static func routeChangeRequiresReadyEngineRebuild(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable,
             .wakeFromSleep, .noSuitableRouteForCategory,
             .routeConfigurationChange:
            true
        case .unknown, .categoryChange, .override:
            false
        @unknown default:
            true
        }
    }

    // MARK: - Explicit Keyboard Ready session

}
