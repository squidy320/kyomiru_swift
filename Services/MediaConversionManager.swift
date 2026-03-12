import Foundation
import AVFoundation

actor MediaConversionManager {
    static let shared = MediaConversionManager()

    enum ConversionError: Error {
        case exportFailed(String)
        case cancelled
    }

    func convertToMp4(inputURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if inputURL.pathExtension.lowercased() == "mp4" {
            return inputURL
        }

        let outputURL = inputURL.deletingPathExtension().appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let coordinator = NSFileCoordinator()
        let intent = NSFileAccessIntent.readingIntent(with: inputURL, options: .withoutChanges)

        return try await withCheckedThrowingContinuation { continuation in
            coordinator.coordinate(with: [intent], queue: .global(qos: .utility)) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let coordinatedURL = intent.url
                let asset = AVURLAsset(url: coordinatedURL)
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    continuation.resume(throwing: ConversionError.exportFailed("AVAssetExportSession init failed"))
                    return
                }

                try? FileManager.default.removeItem(at: outputURL)
                export.outputURL = outputURL
                export.outputFileType = .mp4
                export.shouldOptimizeForNetworkUse = true

                let progressTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                progressTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
                progressTimer.setEventHandler {
                    progress?(Double(export.progress))
                }
                progressTimer.resume()

                export.exportAsynchronously {
                    progressTimer.cancel()

                    switch export.status {
                    case .completed:
                        if coordinatedURL.pathExtension.lowercased() == "ts" {
                            try? FileManager.default.removeItem(at: coordinatedURL)
                        }
                        continuation.resume(returning: outputURL)
                    case .failed:
                        let message = self.describe(export.error)
                        continuation.resume(throwing: ConversionError.exportFailed(message))
                    case .cancelled:
                        continuation.resume(throwing: ConversionError.cancelled)
                    default:
                        let message = self.describe(export.error)
                        continuation.resume(throwing: ConversionError.exportFailed(message))
                    }
                }
            }
        }
    }

    private func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else {
            return "unknown export error"
        }
        let domain = error.domain
        let code = error.code
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("unsupported") {
            return "unsupported container: \(message)"
        }
        if lower.contains("codec") {
            return "codec mismatch: \(message)"
        }
        if domain == AVFoundationErrorDomain {
            return "AVFoundation error code=\(code) \(message)"
        }
        if domain == NSOSStatusErrorDomain {
            return "OSStatus error code=\(code) \(message)"
        }
        return "Export failed (\(domain)) code=\(code) \(message)"
    }
}
