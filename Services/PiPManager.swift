import AVFoundation
import AVKit
import UIKit

#if os(iOS) && !targetEnvironment(macCatalyst)
final class PiPManager: NSObject {
    private let isPlaying: () -> Bool
    private let play: () -> Void
    private let pause: () -> Void
    private let currentTime: () -> Double
    private let duration: () -> Double
    private let skipBy: (Double) -> Void
    private let onStop: () -> Void
    private let onRestore: () -> Void
    private let onStart: () -> Void
    private var controller: AVPictureInPictureController?
    private(set) var isPictureInPictureActive = false

    var isPictureInPicturePossible: Bool {
        controller?.isPictureInPicturePossible ?? false
    }

    init(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer,
        isPlaying: @escaping () -> Bool,
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        currentTime: @escaping () -> Double,
        duration: @escaping () -> Double,
        skipBy: @escaping (Double) -> Void,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.play = play
        self.pause = pause
        self.currentTime = currentTime
        self.duration = duration
        self.skipBy = skipBy
        self.onStart = onStart
        self.onStop = onStop
        self.onRestore = onRestore
        self.controller = nil

        super.init()

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            controller = nil
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.requiresLinearPlayback = false
        pip.delegate = self
        controller = pip
    }

    func startPictureInPicture() {
        AppLog.debug(.player, "pip manager start")
        controller?.startPictureInPicture()
    }

    func stopPictureInPicture() {
        AppLog.debug(.player, "pip manager stop")
        controller?.stopPictureInPicture()
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = true
        AppLog.debug(.player, "pip did start")
        onStart()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
        AppLog.debug(.player, "pip did stop")
        onStop()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isPictureInPictureActive = false
        AppLog.error(.player, "pip failed to start: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.onRestore()
            completionHandler(true)
        }
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            play()
        } else {
            pause()
        }
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !isPlaying()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let start = CMTime(seconds: 0, preferredTimescale: 600)
        let endSeconds = max(duration(), 0)
        let end = CMTime(seconds: endSeconds, preferredTimescale: 600)
        return CMTimeRange(start: start, end: end)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        skipBy(skipInterval.seconds)
        completion()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, playbackTimeDidChange playbackTime: CMTime) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, currentTimeForPlayback time: CMTime) -> CMTime {
        return CMTime(seconds: currentTime(), preferredTimescale: 600)
    }
}
#endif
