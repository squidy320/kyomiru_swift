import SwiftUI
import UIKit
import CryptoKit
import Foundation
import ImageIO

enum Theme {
    private static let accentRedKey = "settings.accentColor.red"
    private static let accentGreenKey = "settings.accentColor.green"
    private static let accentBlueKey = "settings.accentColor.blue"

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
    }

    static var baseBackground: Color {
        adaptiveColor(
            light: UIColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1.0),
            dark: UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
        )
    }

    static var surface: Color {
        adaptiveColor(
            light: UIColor(red: 0.22, green: 0.24, blue: 0.30, alpha: 1.0),
            dark: UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        )
    }

    static var accent: Color {
        let defaults = UserDefaults.standard
        let red = defaults.object(forKey: accentRedKey) as? Double ?? 0.47
        let green = defaults.object(forKey: accentGreenKey) as? Double ?? 0.72
        let blue = defaults.object(forKey: accentBlueKey) as? Double ?? 1.0
        return Color(red: red, green: green, blue: blue)
    }
    static var textPrimary: Color {
        adaptiveColor(
            light: .white,
            dark: .white
        )
    }

    static var textSecondary: Color {
        adaptiveColor(
            light: UIColor(red: 0.79, green: 0.82, blue: 0.89, alpha: 1.0),
            dark: UIColor(red: 0.63, green: 0.66, blue: 0.74, alpha: 1.0)
        )
    }

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                adaptiveColor(
                    light: UIColor(red: 0.23, green: 0.25, blue: 0.31, alpha: 1.0),
                    dark: UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
                ),
                adaptiveColor(
                    light: UIColor(red: 0.14, green: 0.15, blue: 0.20, alpha: 1.0),
                    dark: UIColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1.0)
                )
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

actor ImageCache {
    static let shared = ImageCache()

    private static let diskSizeLimitBytes: Int64 = 250 * 1024 * 1024
    private let memory = NSCache<NSString, NSData>()
    private let renderedImages = NSCache<NSString, UIImage>()
    private let folder: URL
    private let session: URLSession
    private var dataTasks: [String: Task<Data?, Never>] = [:]
    private var imageTasks: [String: Task<UIImage?, Never>] = [:]

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("KyomiruImageCache", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 120 * 1024 * 1024,
            diskPath: "KyomiruURLCache"
        )
        session = URLSession(configuration: config)
        memory.totalCostLimit = 40 * 1024 * 1024
        memory.countLimit = 200
        renderedImages.totalCostLimit = 60 * 1024 * 1024
        renderedImages.countLimit = 250
    }

    func data(for url: URL) async -> Data? {
        let keyString = cacheKey(for: url)
        let key = keyString as NSString
        if let cached = memory.object(forKey: key) {
            return cached as Data
        }

        let fileURL = fileURLFor(url: url)
        if let data = try? Data(contentsOf: fileURL) {
            memory.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        }

        if let existing = dataTasks[keyString] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return nil
                }
                return data
            } catch {
                return nil
            }
        }
        dataTasks[keyString] = task
        let data = await task.value
        dataTasks[keyString] = nil

        guard let data else { return nil }
        memory.setObject(data as NSData, forKey: key, cost: data.count)
        try? data.write(to: fileURL, options: .atomic)
        pruneDiskCacheIfNeeded()
        return data
    }

    func prefetch(urls: [URL]) async {
        let unique = Array(Set(urls))
        if unique.isEmpty { return }
        for url in unique {
            let key = cacheKey(for: url)
            let memoryKey = key as NSString
            if memory.object(forKey: memoryKey) != nil { continue }
            let fileURL = fileURLFor(url: url)
            if FileManager.default.fileExists(atPath: fileURL.path) { continue }
            if dataTasks[key] != nil { continue }
            Task {
                _ = await data(for: url)
            }
        }
    }

    func clearAll() async {
        memory.removeAllObjects()
        renderedImages.removeAllObjects()
        dataTasks.removeAll()
        imageTasks.removeAll()
        session.configuration.urlCache?.removeAllCachedResponses()
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func fileURLFor(url: URL) -> URL {
        let name = sha256(cacheKey(for: url))
        return folder.appendingPathComponent(name).appendingPathExtension("img")
    }

    private func cacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.fragment = nil
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()

        let queryHostsToStrip: Set<String> = [
            "image.tmdb.org",
            "s4.anilist.co",
            "img.anili.st",
            "cdn.myanimelist.net"
        ]
        if let host = components.host, queryHostsToStrip.contains(host) {
            components.query = nil
        }

        return components.string ?? url.absoluteString
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func pruneDiskCacheIfNeeded() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, modified: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let fileSize = Int64(values.fileSize ?? 0)
            totalSize += fileSize
            files.append((fileURL, values.contentModificationDate ?? .distantPast, fileSize))
        }

        guard totalSize > Self.diskSizeLimitBytes else { return }

        for file in files.sorted(by: { $0.modified < $1.modified }) {
            try? fm.removeItem(at: file.url)
            totalSize -= file.size
            if totalSize <= Self.diskSizeLimitBytes {
                break
            }
        }
    }

    func image(for url: URL, targetSize: CGSize, scale: CGFloat) async -> UIImage? {
        let renderedKey = "\(cacheKey(for: url))::\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))@\(Int(scale.rounded()))" as NSString
        if let cached = renderedImages.object(forKey: renderedKey) {
            return cached
        }

        if let existing = imageTasks[renderedKey as String] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            guard let data = await self.data(for: url) else { return nil }
            return await Task.detached(priority: .utility) {
                ImageCache.downsample(data: data, targetSize: targetSize, scale: scale)
            }.value
        }
        imageTasks[renderedKey as String] = task
        let image = await task.value
        imageTasks[renderedKey as String] = nil

        if let image, let cgImage = image.cgImage {
            let cost = cgImage.bytesPerRow * cgImage.height
            renderedImages.setObject(image, forKey: renderedKey, cost: cost)
        }
        return image
    }

    private nonisolated static func downsample(data: Data, targetSize: CGSize, scale: CGFloat) -> UIImage? {
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

    init(
        url: URL?,
        targetSize: CGSize? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetSize = targetSize
        self.content = content
        self.placeholder = placeholder
    }

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
        await MainActor.run { uiImage = nil }
        if let targetSize {
            let scale = await MainActor.run { UIScreen.main.scale }
            if let image = await ImageCache.shared.image(for: url, targetSize: targetSize, scale: scale) {
                await MainActor.run { uiImage = image }
                return
            }
        }
        if let data = await ImageCache.shared.data(for: url),
           let image = UIImage(data: data) {
            await MainActor.run { uiImage = image }
        } else {
            await MainActor.run { uiImage = nil }
        }
    }
}
