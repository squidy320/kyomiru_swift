import Foundation

struct DownloadItem: Identifiable, Equatable {
    let id: String
    let title: String
    let episode: Int
    let url: URL
    var progress: Double
    var localFile: URL?
    var status: String
    var isHls: Bool
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published private(set) var items: [DownloadItem] = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "kyomiru.downloads")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let fm = FileManager.default
    private let indexKey = "downloads_index.json"

    override init() {
        super.init()
        loadIndex()
    }

    func enqueue(title: String, episode: Int, url: URL) {
        let id = "\(title)|\(episode)|\(url.absoluteString)"
        if items.contains(where: { $0.id == id }) {
            AppLog.downloads.debug("download already queued id=\(id, privacy: .public)")
            return
        }
        let item = DownloadItem(id: id, title: title, episode: episode, url: url, progress: 0, localFile: nil, status: "Queued", isHls: false)
        items.append(item)
        saveIndex()
        AppLog.downloads.debug("download enqueue id=\(id, privacy: .public)")
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        task.resume()
        updateStatus(id: id, status: "Downloading")
    }

    func enqueueHLS(title: String, episode: Int, url: URL, headers: [String: String]) {
        let id = "\(title)|\(episode)|\(url.absoluteString)"
        if items.contains(where: { $0.id == id }) {
            AppLog.downloads.debug("hls already queued id=\(id, privacy: .public)")
            return
        }
        let item = DownloadItem(id: id, title: title, episode: episode, url: url, progress: 0, localFile: nil, status: "Queued", isHls: true)
        items.append(item)
        saveIndex()
        updateStatus(id: id, status: "Downloading HLS")
        AppLog.downloads.debug("hls enqueue id=\(id, privacy: .public)")
        Task { await downloadHLS(id: id, url: url, headers: headers) }
    }

    func localFileURL(for title: String, episode: Int) -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads/\(safe(title))", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("E\(episode).mp4")
    }

    private func localHLSFolder(title: String, episode: Int) -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads/\(safe(title))/E\(episode)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "_")
    }

    private func updateProgress(id: String, progress: Double) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].progress = progress
            saveIndex()
        }
    }

    private func updateStatus(id: String, status: String, localFile: URL? = nil) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = status
            if let localFile { items[idx].localFile = localFile }
            saveIndex()
            AppLog.downloads.debug("download status id=\(id, privacy: .public) status=\(status, privacy: .public)")
        }
    }

    private func downloadHLS(id: String, url: URL, headers: [String: String]) async {
        do {
            AppLog.downloads.debug("hls download start id=\(id, privacy: .public)")
            var request = URLRequest(url: url)
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let playlist = String(data: data, encoding: .utf8) else {
                updateStatus(id: id, status: "Failed")
                AppLog.downloads.error("hls playlist decode failed id=\(id, privacy: .public)")
                return
            }
            let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false)
            let segmentLines = lines.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var localLines: [String] = []
            let folder = localHLSFolder(title: items.first(where: { $0.id == id })?.title ?? "Unknown", episode: items.first(where: { $0.id == id })?.episode ?? 0)
            var index = 0
            let total = max(segmentLines.count, 1)
            var keyURLString: String?
            var keyLocalPath: String?
            updateProgress(id: id, progress: 0)

            for line in lines {
                if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let str = String(line)
                    if str.contains("#EXT-X-KEY") {
                        if let uriRange = str.range(of: "URI=\"") {
                            let tail = str[uriRange.upperBound...]
                            if let end = tail.firstIndex(of: "\"") {
                                keyURLString = String(tail[..<end])
                            }
                        }
                    }
                    localLines.append(str)
                    continue
                }
                let raw = String(line).trimmingCharacters(in: .whitespaces)
                let segmentURL = URL(string: raw, relativeTo: url)?.absoluteURL ?? URL(string: raw)
                guard let segURL = segmentURL else {
                    localLines.append(raw)
                    continue
                }
                let localName = String(format: "seg_%04d.ts", index)
                let localFile = folder.appendingPathComponent(localName)
                var segRequest = URLRequest(url: segURL)
                for (k, v) in headers {
                    segRequest.setValue(v, forHTTPHeaderField: k)
                }
                let (segData, _) = try await URLSession.shared.data(for: segRequest)
                try segData.write(to: localFile, options: .atomic)
                localLines.append(localName)
                index += 1
                updateProgress(id: id, progress: Double(index) / Double(total))
            }

            if let keyURLString {
                let keyURL = URL(string: keyURLString, relativeTo: url)?.absoluteURL ?? URL(string: keyURLString)
                if let keyURL {
                    var keyRequest = URLRequest(url: keyURL)
                    for (k, v) in headers {
                        keyRequest.setValue(v, forHTTPHeaderField: k)
                    }
                    let (keyData, _) = try await URLSession.shared.data(for: keyRequest)
                    let keyFile = folder.appendingPathComponent("key.bin")
                    try keyData.write(to: keyFile, options: .atomic)
                    keyLocalPath = "key.bin"
                }
            }

            if let keyLocalPath {
                localLines = localLines.map { line in
                    if line.contains("#EXT-X-KEY"), line.contains("URI=\"") {
                        return line.replacingOccurrences(of: #"URI="[^"]+""#, with: "URI=\"\(keyLocalPath)\"", options: .regularExpression)
                    }
                    return line
                }
            }

            let localPlaylist = localLines.joined(separator: "\n")
            let playlistURL = folder.appendingPathComponent("index.m3u8")
            try localPlaylist.data(using: .utf8)?.write(to: playlistURL, options: .atomic)
            updateStatus(id: id, status: "Completed", localFile: playlistURL)
            AppLog.downloads.debug("hls download complete id=\(id, privacy: .public)")
            if let item = items.first(where: { $0.id == id }) {
                markWatched(mediaTitle: item.title, episode: item.episode)
            }
        } catch {
            updateStatus(id: id, status: "Failed")
            AppLog.downloads.error("hls download failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let item = items.first(where: { $0.id == id }) else { return }
        let target = localFileURL(for: item.title, episode: item.episode)
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: location, to: target)
            updateStatus(id: id, status: "Completed", localFile: target)
            AppLog.downloads.debug("download complete id=\(id, privacy: .public)")
            markWatched(mediaTitle: item.title, episode: item.episode)
        } catch {
            updateStatus(id: id, status: "Failed")
            AppLog.downloads.error("download failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let id = downloadTask.taskDescription else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        updateProgress(id: id, progress: progress)
    }

    func delete(itemId: String) {
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            if let localFile = items[idx].localFile {
                try? fm.removeItem(at: localFile)
                let folder = localFile.deletingLastPathComponent()
                try? fm.removeItem(at: folder)
            }
            items.remove(at: idx)
            saveIndex()
            AppLog.downloads.debug("download delete id=\(itemId, privacy: .public)")
        }
    }

    func markWatched(mediaTitle: String, episode: Int) {
        AppLog.downloads.debug("mark watched title=\(mediaTitle, privacy: .public) ep=\(episode)")
        NotificationCenter.default.post(
            name: .downloadCompleted,
            object: nil,
            userInfo: ["title": mediaTitle, "episode": episode]
        )
    }

    private func loadIndex() {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([PersistedDownload].self, from: data) else { return }
        items = decoded.map { $0.asItem() }
        AppLog.downloads.debug("download index loaded count=\(items.count)")
    }

    private func saveIndex() {
        let url = indexURL()
        let payload = items.map { PersistedDownload(from: $0) }
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func indexURL() -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(indexKey)
    }
}

private struct PersistedDownload: Codable {
    let id: String
    let title: String
    let episode: Int
    let url: String
    let progress: Double
    let localFile: String?
    let status: String
    let isHls: Bool

    init(from item: DownloadItem) {
        id = item.id
        title = item.title
        episode = item.episode
        url = item.url.absoluteString
        progress = item.progress
        localFile = item.localFile?.absoluteString
        status = item.status
        isHls = item.isHls
    }

    func asItem() -> DownloadItem {
        DownloadItem(
            id: id,
            title: title,
            episode: episode,
            url: URL(string: url)!,
            progress: progress,
            localFile: localFile.flatMap(URL.init(string:)),
            status: status,
            isHls: isHls
        )
    }
}
