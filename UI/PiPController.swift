#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
import AVKit
import UIKit

final class PiPController: NSObject {
    private let isPlaying: () -> Bool
    private let play: () -> Void
    private let pause: () -> Void
    private let currentTime: () -> Double
    private let duration: () -> Double
    private let skipBy: (Double) -> Void
    private let onStop: () -> Void
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
        onStop: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.play = play
        self.pause = pause
        self.currentTime = currentTime
        self.duration = duration
        self.skipBy = skipBy
        self.onStop = onStop
        self.controller = nil

        super.init()

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleBufferDisplayLayer,
                playbackDelegate: self
            )
            let pip = AVPictureInPictureController(contentSource: source)
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pip.delegate = self
            controller = pip
        } else {
            controller = nil
        }
    }

    func startPictureInPicture() {
        controller?.startPictureInPicture()
    }

    func stopPictureInPicture() {
        controller?.stopPictureInPicture()
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {}

extension PiPController {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
        onStop()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isPictureInPictureActive = false
    }
}

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
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
