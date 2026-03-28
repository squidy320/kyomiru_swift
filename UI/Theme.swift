import SwiftUI
import UIKit
import CryptoKit
import Foundation
import ImageIO
import CoreGraphics

enum Theme {
    struct HeroTintStyle {
        let pageBackground: [Color]
        let heroTop: [Color]
        let heroBottom: [Color]
        let heroFooter: [Color]
    }

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static let darkBase = UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
    private static let darkSurface = UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)

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

    static let accent = Color(red: 0.47, green: 0.72, blue: 1.0)
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

    static func heroTintStyle(from accent: UIColor?) -> HeroTintStyle {
        let normalized = accent.map(normalizeHeroAccent(_:))
        let topBase = normalized.map { mix($0, with: darkSurface, ratio: 0.42) } ?? darkSurface
        let midBase = normalized.map { mix($0, with: darkBase, ratio: 0.58) } ?? darkBase
        let bottomBase = normalized.map { mix($0, with: .black, ratio: 0.72) } ?? UIColor.black
        let footerBase = normalized.map { mix($0, with: .black, ratio: 0.64) } ?? UIColor.black

        return HeroTintStyle(
            pageBackground: [
                Color(uiColor: topBase),
                Color(uiColor: midBase),
                Color(uiColor: darkBase)
            ],
            heroTop: [
                Color(uiColor: topBase).opacity(0.7),
                Color(uiColor: midBase).opacity(0.18),
                .clear
            ],
            heroBottom: [
                Color(uiColor: bottomBase).opacity(0.96),
                Color(uiColor: midBase).opacity(0.62),
                .clear
            ],
            heroFooter: [
                .clear,
                Color(uiColor: footerBase).opacity(0.9)
            ]
        )
    }

    private static func mix(_ color: UIColor, with other: UIColor, ratio: CGFloat) -> UIColor {
        let clamped = min(max(ratio, 0), 1)
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: (r1 * (1 - clamped)) + (r2 * clamped),
            green: (g1 * (1 - clamped)) + (g2 * clamped),
            blue: (b1 * (1 - clamped)) + (b2 * clamped),
            alpha: (a1 * (1 - clamped)) + (a2 * clamped)
        )
    }

    private static func normalizeHeroAccent(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            let adjustedSaturation = min(max((saturation * 0.72) + 0.12, 0.18), 0.58)
            let adjustedBrightness = min(max((brightness * 0.5) + 0.16, 0.26), 0.56)
            return UIColor(hue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness, alpha: 1.0)
        }

        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            let adjusted = min(max((white * 0.45) + 0.18, 0.24), 0.5)
            return UIColor(white: adjusted, alpha: 1.0)
        }
        return darkSurface
    }
}

actor ImageAccentColorCache {
    static let shared = ImageAccentColorCache()

    private enum Entry {
        case value(UIColor)
        case missing
    }

    private var cache: [String: Entry] = [:]

    func accentColor(for url: URL) async -> UIColor? {
        let key = url.absoluteString
        if let cached = cache[key] {
            switch cached {
            case .value(let color):
                return color
            case .missing:
                return nil
            }
        }

        guard let image = await ImageCache.shared.image(for: url, targetSize: CGSize(width: 32, height: 32), scale: 1),
              let color = dominantColor(from: image) else {
            cache[key] = .missing
            return nil
        }

        cache[key] = .value(color)
        return color
    }

    private func dominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 16
        let height = 16
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var weight: CGFloat = 0

        for index in stride(from: 0, to: data.count, by: 4) {
            let alpha = CGFloat(data[index + 3]) / 255
            if alpha < 0.05 { continue }
            let r = CGFloat(data[index]) / 255
            let g = CGFloat(data[index + 1]) / 255
            let b = CGFloat(data[index + 2]) / 255
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
            let pixelWeight = max(0.2, saturation + (alpha * 0.4))
            red += r * pixelWeight
            green += g * pixelWeight
            blue += b * pixelWeight
            weight += pixelWeight
        }

        guard weight > 0 else { return nil }
        return UIColor(red: red / weight, green: green / weight, blue: blue / weight, alpha: 1.0)
    }
}

actor ImageCache {
    static let shared = ImageCache()

    private static let diskSizeLimitBytes: Int64 = 250 * 1024 * 1024
    private let memory = NSCache<NSString, NSData>()
    private let folder: URL
    private let session: URLSession
    private var inFlight: Set<String> = []

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("KyomiruImageCache", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        config.urlCache = nil
        session = URLSession(configuration: config)
        memory.totalCostLimit = 40 * 1024 * 1024
        memory.countLimit = 200
    }

    func data(for url: URL) async -> Data? {
        let key = cacheKey(for: url) as NSString
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
                pruneDiskCacheIfNeeded()
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
            let key = cacheKey(for: url)
            let memoryKey = key as NSString
            if memory.object(forKey: memoryKey) != nil { continue }
            let fileURL = fileURLFor(url: url)
            if FileManager.default.fileExists(atPath: fileURL.path) { continue }
            if inFlight.contains(key) { continue }
            inFlight.insert(key)
            Task {
                _ = await data(for: url)
                await removeInFlight(key)
            }
        }
    }

    private func removeInFlight(_ key: String) async {
        inFlight.remove(key)
    }

    func clearAll() async {
        memory.removeAllObjects()
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
