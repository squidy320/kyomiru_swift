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
    private let controller: AVPictureInPictureController?

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
        skipBy: @escaping (Double) -> Void
    ) {
        self.isPlaying = isPlaying
        self.play = play
        self.pause = pause
        self.currentTime = currentTime
        self.duration = duration
        self.skipBy = skipBy

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleBufferDisplayLayer,
                playbackDelegate: self
            )
            let pip = AVPictureInPictureController(contentSource: source)
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            controller = pip
        } else {
            controller = nil
        }

        super.init()

        if let controller {
            controller.delegate = self
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

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, timeRangeForPlayback timeRange: CMTimeRange) -> CMTimeRange {
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
