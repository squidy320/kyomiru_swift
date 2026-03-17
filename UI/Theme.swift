import SwiftUI
import UIKit
import CryptoKit
import Foundation
import ImageIO

enum Theme {
    static let baseBackground = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let surface = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let accent = Color(red: 0.47, green: 0.72, blue: 1.0)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.63, green: 0.66, blue: 0.74)

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.09, blue: 0.12),
            Color(red: 0.03, green: 0.03, blue: 0.05)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

actor ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, NSData>()
    private let folder: URL
    private let session: URLSession
    private var inFlight: Set<URL> = []

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("KyomiruImageCache", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: "KyomiruURLCache"
        )
        session = URLSession(configuration: config)
        memory.totalCostLimit = 40 * 1024 * 1024
        memory.countLimit = 200
    }

    func data(for url: URL) async -> Data? {
        let key = url as NSURL
        if let cached = memory.object(forKey: key) {
            return cached as Data
        }

        let fileURL = fileURLFor(url: url)
        if let data = try? Data(contentsOf: fileURL) {
            memory.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                memory.setObject(data as NSData, forKey: key, cost: data.count)
                try? data.write(to: fileURL, options: .atomic)
                return data
            }
        } catch {
            return nil
        }
        return nil
    }

    func prefetch(urls: [URL]) async {
        let unique = Array(Set(urls))
        if unique.isEmpty { return }
        for url in unique {
            let key = url as NSURL
            if memory.object(forKey: key) != nil { continue }
            let fileURL = fileURLFor(url: url)
            if FileManager.default.fileExists(atPath: fileURL.path) { continue }
            if inFlight.contains(url) { continue }
            inFlight.insert(url)
            Task {
                _ = await data(for: url)
                await removeInFlight(url)
            }
        }
    }

    private func removeInFlight(_ url: URL) async {
        inFlight.remove(url)
    }

    func clearAll() async {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func fileURLFor(url: URL) -> URL {
        let name = sha256(url.absoluteString)
        return folder.appendingPathComponent(name).appendingPathExtension("img")
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func image(for url: URL, targetSize: CGSize, scale: CGFloat = UIScreen.main.scale) async -> UIImage? {
        guard let data = await data(for: url) else { return nil }
        return downsample(data: data, targetSize: targetSize, scale: scale)
    }

    private func downsample(data: Data, targetSize: CGSize, scale: CGFloat) -> UIImage? {
        let maxDimension = max(targetSize.width, targetSize.height) * scale
        guard maxDimension > 0 else { return nil }
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let downsampleOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let targetSize: CGSize?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            await MainActor.run { uiImage = nil }
            return
        }
        if let targetSize,
           let image = await ImageCache.shared.image(for: url, targetSize: targetSize) {
            await MainActor.run { uiImage = image }
            return
        }
        if let data = await ImageCache.shared.data(for: url),
           let image = UIImage(data: data) {
            await MainActor.run { uiImage = image }
        } else {
            await MainActor.run { uiImage = nil }
        }
    }
}
