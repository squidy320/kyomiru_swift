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
            light: .white,
            dark: .black
        )
    }

    static var surface: Color {
        adaptiveColor(
            light: .white,
            dark: .black
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
            light: UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1.0),
            dark: .white
        )
    }

    static var textSecondary: Color {
        adaptiveColor(
            light: UIColor(red: 0.38, green: 0.43, blue: 0.52, alpha: 1.0),
            dark: UIColor(red: 0.63, green: 0.66, blue: 0.74, alpha: 1.0)
        )
    }

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                adaptiveColor(
                    light: .white,
                    dark: .black
                ),
                adaptiveColor(
                    light: .white,
                    dark: .black
                )
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct HeroAtmosphereColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(uiColor: UIColor) {
        let rgba = uiColor.rgbaComponents
        self.red = Double(rgba.red)
        self.green = Double(rgba.green)
        self.blue = Double(rgba.blue)
        self.alpha = Double(rgba.alpha)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct HeroAtmosphere: Sendable {
    let base: HeroAtmosphereColor
    let top: HeroAtmosphereColor
    let bottom: HeroAtmosphereColor

    var baseBackground: Color { base.color }
    var topFeather: Color { top.color }
    var bottomFeather: Color { bottom.color }

    static let fallback = HeroAtmosphere(
        base: HeroAtmosphereColor(red: 0.0, green: 0.0, blue: 0.0),
        top: HeroAtmosphereColor(red: 0.0, green: 0.0, blue: 0.0),
        bottom: HeroAtmosphereColor(red: 0.0, green: 0.0, blue: 0.0)
    )

    static let neutralBlack = HeroAtmosphere(
        base: HeroAtmosphereColor(red: 0.0, green: 0.0, blue: 0.0),
        top: HeroAtmosphereColor(red: 0.0, green: 0.0, blue: 0.0),
        bottom: HeroAtmosphereColor(red: 0.0, green: 0.0, blue: 0.0)
    )
}

actor HeroAtmosphereResolver {
    static let shared = HeroAtmosphereResolver()

    private var cache: [String: HeroAtmosphere] = [:]
    private var tasks: [String: Task<HeroAtmosphere, Never>] = [:]

    func atmosphere(for url: URL?) async -> HeroAtmosphere {
        guard let url else { return .fallback }
        let key = url.absoluteString
        if let cached = cache[key] {
            return cached
        }
        if let existing = tasks[key] {
            return await existing.value
        }

        let task = Task<HeroAtmosphere, Never> {
            let targetSize = CGSize(width: 96, height: 96)
            let image = await ImageCache.shared.image(for: url, targetSize: targetSize, scale: 1)
            guard let image,
                  let color = await self.representativeColor(from: image) else {
                return .fallback
            }
            return Self.makeAtmosphere(from: color)
        }

        tasks[key] = task
        let atmosphere = await task.value
        tasks[key] = nil
        cache[key] = atmosphere
        return atmosphere
    }

    private func representativeColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let width = 24
        let height = 24
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var weightedRed: CGFloat = 0
        var weightedGreen: CGFloat = 0
        var weightedBlue: CGFloat = 0
        var totalWeight: CGFloat = 0

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = CGFloat(pixels[index]) / 255.0
            let green = CGFloat(pixels[index + 1]) / 255.0
            let blue = CGFloat(pixels[index + 2]) / 255.0
            let alpha = CGFloat(pixels[index + 3]) / 255.0
            if alpha < 0.4 { continue }

            let color = UIColor(red: red, green: green, blue: blue, alpha: 1.0)
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var outAlpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &outAlpha) else {
                continue
            }

            if brightness < 0.14 || brightness > 0.95 {
                continue
            }

            let saturationBoost = max(saturation, 0.08)
            let brightnessWeight = 1.0 - abs(brightness - 0.56)
            
            // Bias toward warm tones (reds, oranges, yellows: hue 0-90°)
            let warmthBoost: CGFloat
            if hue < 0.25 {
                // Strong boost for warm tones (0-90°)
                warmthBoost = 1.3
            } else if hue > 0.75 {
                // Slight boost for reds wrapping around (270-360°)
                warmthBoost = 1.1
            } else {
                warmthBoost = 1.0
            }
            
            let weight = max(0.05, ((saturationBoost * 1.45) + (brightnessWeight * 0.6)) * warmthBoost)

            weightedRed += red * weight
            weightedGreen += green * weight
            weightedBlue += blue * weight
            totalWeight += weight
        }

        if totalWeight <= 0.0001 {
            return averageColor(from: pixels, bytesPerPixel: bytesPerPixel)
        }

        return UIColor(
            red: weightedRed / totalWeight,
            green: weightedGreen / totalWeight,
            blue: weightedBlue / totalWeight,
            alpha: 1.0
        )
    }

    private func averageColor(from pixels: [UInt8], bytesPerPixel: Int) -> UIColor? {
        var totalRed: CGFloat = 0
        var totalGreen: CGFloat = 0
        var totalBlue: CGFloat = 0
        var count: CGFloat = 0

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = CGFloat(pixels[index + 3]) / 255.0
            if alpha < 0.4 { continue }
            totalRed += CGFloat(pixels[index]) / 255.0
            totalGreen += CGFloat(pixels[index + 1]) / 255.0
            totalBlue += CGFloat(pixels[index + 2]) / 255.0
            count += 1
        }

        guard count > 0 else { return nil }
        return UIColor(
            red: totalRed / count,
            green: totalGreen / count,
            blue: totalBlue / count,
            alpha: 1.0
        )
    }

    private static func makeAtmosphere(from color: UIColor) -> HeroAtmosphere {
        let neutralBase = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        let neutralTop = UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
        let neutralBottom = UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        let seed = color.normalizedHeroSeed()

        let base = seed
            .blended(with: neutralBase, amount: 0.35)
            .adjustingBrightness(by: 0.92)
        let top = seed
            .blended(with: neutralTop, amount: 0.30)
            .adjustingBrightness(by: 0.98)
        let bottom = seed
            .blended(with: neutralBottom, amount: 0.25)
            .adjustingBrightness(by: 0.84)

        return HeroAtmosphere(
            base: HeroAtmosphereColor(uiColor: base),
            top: HeroAtmosphereColor(uiColor: top),
            bottom: HeroAtmosphereColor(uiColor: bottom)
        )
    }
}

private extension UIColor {
    func normalizedHeroSeed() -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        if getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            let clampedSaturation = min(max(saturation * 1.32, 0.34), 0.82)
            let clampedBrightness = min(max(brightness * 1.02, 0.42), 0.78)
            return UIColor(hue: hue, saturation: clampedSaturation, brightness: clampedBrightness, alpha: 1.0)
        }

        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            let clampedWhite = min(max(white, 0.34), 0.64)
            return UIColor(white: clampedWhite, alpha: 1.0)
        }

        return self
    }

    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        let blendAmount = min(max(amount, 0), 1)
        let base = rgbaComponents
        let target = other.rgbaComponents
        let inverse = 1 - blendAmount
        return UIColor(
            red: (base.red * inverse) + (target.red * blendAmount),
            green: (base.green * inverse) + (target.green * blendAmount),
            blue: (base.blue * inverse) + (target.blue * blendAmount),
            alpha: (base.alpha * inverse) + (target.alpha * blendAmount)
        )
    }

    func adjustingBrightness(by factor: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        if getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            return UIColor(
                hue: hue,
                saturation: saturation,
                brightness: min(max(brightness * factor, 0), 1),
                alpha: alpha
            )
        }

        let rgba = rgbaComponents
        return UIColor(
            red: min(max(rgba.red * factor, 0), 1),
            green: min(max(rgba.green * factor, 0), 1),
            blue: min(max(rgba.blue * factor, 0), 1),
            alpha: rgba.alpha
        )
    }

    var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return (red, green, blue, alpha)
        }

        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            return (white, white, white, alpha)
        }

        return (0, 0, 0, 1)
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
