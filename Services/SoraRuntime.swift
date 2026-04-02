import Foundation

struct SourceModuleStreamResult {
    let streams: [String]?
    let subtitles: [String]?
    let sources: [[String: Any]]?
}

private struct SourceProviderConfiguration {
    let provider: StreamingProvider
    let sourceURL: URL
    let scriptURL: URL
    let baseURL: URL
    let metadata: ServiceMetadata
    let supportsDirectSearch: Bool
    let supportsDirectEpisodes: Bool
    let scriptPatches: [(String, String)]
    let searchTimeout: Double
    let episodeTimeout: Double
    let sourceTimeout: Double
    let logKey: String

    static func make(for provider: StreamingProvider) -> SourceProviderConfiguration {
        let resolvedMetadata = StreamingExtensionManager.cachedMetadata(for: provider) ?? provider.fallbackMetadata
        let resolvedScriptURL = URL(string: resolvedMetadata.scriptUrl)
            ?? URL(string: provider.fallbackMetadata.scriptUrl)!
        let resolvedBaseURL = URL(string: resolvedMetadata.baseUrl)
            ?? URL(string: provider.fallbackMetadata.baseUrl)!
        switch provider {
        case .animePahe:
            return SourceProviderConfiguration(
                provider: .animePahe,
                sourceURL: provider.manifestURL,
                scriptURL: resolvedScriptURL,
                baseURL: resolvedBaseURL,
                metadata: resolvedMetadata,
                supportsDirectSearch: true,
                supportsDirectEpisodes: true,
                scriptPatches: [
                    ("match(/<div class=\"anime-synopsis\">(.*?)<\\/div>/s)", "match(/<div class=\\\"anime-synopsis\\\">([\\s\\S]*?)<\\/div>/)"),
                    ("match(/<strong>Aired:<\\/strong>(.*?)<\\/p>/s)", "match(/<strong>Aired:<\\/strong>([\\s\\S]*?)<\\/p>/)"),
                    ("match(/<script>(.*?)<\\/script>/s)", "match(/<script>([\\s\\S]*?)<\\/script>/)")
                ],
                searchTimeout: 12,
                episodeTimeout: 35,
                sourceTimeout: 35,
                logKey: "animepahe"
            )
        case .animeKai:
            return SourceProviderConfiguration(
                provider: .animeKai,
                sourceURL: provider.manifestURL,
                scriptURL: resolvedScriptURL,
                baseURL: resolvedBaseURL,
                metadata: resolvedMetadata,
                supportsDirectSearch: false,
                supportsDirectEpisodes: false,
                scriptPatches: [],
                searchTimeout: 15,
                episodeTimeout: 35,
                sourceTimeout: 35,
                logKey: "animekai"
            )
        }
    }
}

final class SourceModuleService {
    private let session: URLSession
    private let config: SourceProviderConfiguration
    private let js = JSController.shared
    private var loadedService: Service?
    private var loadedAt: Date?

    init(config: SourceProviderConfiguration, session: URLSession = .custom) {
        self.config = config
        self.session = session
    }

    func search(query: String) async throws -> [SearchItem] {
        let service = try await loadServiceIfNeeded()
        AppLog.debug(.network, "\(config.logKey) module search using hardcoded source=\(config.sourceURL.absoluteString)")
        return try await withOperationTimeout(seconds: config.searchTimeout, label: "\(config.logKey) module search") {
            await withCheckedContinuation { [self] cont in
                self.js.fetchJsSearchResults(keyword: query, module: service) { results in
                    cont.resume(returning: results)
                }
            }
        }
    }

    func episodes(animeURL: URL) async throws -> [EpisodeLink] {
        _ = try await loadServiceIfNeeded()
        return try await withOperationTimeout(seconds: config.episodeTimeout, label: "\(config.logKey) module episodes") {
            await withCheckedContinuation { [self] cont in
                self.js.fetchEpisodesJS(url: animeURL.absoluteString) { results in
                    cont.resume(returning: results)
                }
            }
        }
    }

    func sources(episodeURL: URL) async throws -> SourceModuleStreamResult {
        let service = try await loadServiceIfNeeded()
        let result = try await withOperationTimeout(seconds: config.sourceTimeout, label: "\(config.logKey) module sources") {
            await withCheckedContinuation { [self] cont in
                self.js.fetchStreamUrlJS(episodeUrl: episodeURL.absoluteString, module: service) { result in
                    cont.resume(returning: result)
                }
            }
        }
        return SourceModuleStreamResult(
            streams: result.streams,
            subtitles: result.subtitles,
            sources: result.sources
        )
    }

    private func withOperationTimeout<T>(
        seconds: Double,
        label: String,
        operation: @escaping () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            let result = try await group.next()!
            group.cancelAll()
            AppLog.debug(.network, "\(label) success")
            return result
        }
    }

    private func loadServiceIfNeeded() async throws -> Service {
        let now = Date()
        if let service = loadedService,
           let loadedAt,
           now.timeIntervalSince(loadedAt) < 1800 {
            AppLog.debug(.network, "\(config.logKey) module cache hit")
            return service
        }

        AppLog.debug(.network, "\(config.logKey) module hardcoded bootstrap source=\(config.sourceURL.absoluteString) script=\(config.scriptURL.absoluteString)")
        var scriptRequest = URLRequest(url: config.scriptURL)
        scriptRequest.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        scriptRequest.setValue("text/javascript,*/*", forHTTPHeaderField: "Accept")
        let (scriptData, _) = try await fetch(scriptRequest, label: "\(config.logKey)-module-script")
        var script = String(data: scriptData, encoding: .utf8) ?? ""
        if script.isEmpty {
            throw URLError(.cannotDecodeContentData)
        }

        for patch in config.scriptPatches {
            script = script.replacingOccurrences(of: patch.0, with: patch.1)
        }

        let service = Service(
            id: UUID(),
            metadata: config.metadata,
            jsScript: script,
            url: config.sourceURL.absoluteString,
            isActive: true,
            sortIndex: 0
        )

        loadedService = service
        loadedAt = now
        js.loadScript(script)
        AppLog.debug(.network, "\(config.logKey) module script loaded into JSContext size=\(script.count)")
        return service
    }

    private func fetch(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        try await NetworkRetry.withRetries(label: label) { [session] in
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 || http.statusCode == 429 {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }
    }
}

final class SoraRuntime {
    private let config: SourceProviderConfiguration
    private let baseURL: URL
    private let session: URLSession
    private var cookieHeader: String?
    private let moduleService: SourceModuleService
    private let searchTasks = InFlightStringTaskStore<[SoraAnimeMatch]>()

    init(provider: StreamingProvider = .current, session: URLSession = .custom) {
        self.config = SourceProviderConfiguration.make(for: provider)
        self.baseURL = self.config.baseURL
        self.session = session
        self.moduleService = SourceModuleService(config: self.config, session: session)
    }

    func searchAnime(query: String) async throws -> [SoraAnimeMatch] {
        let trimmed = normalizeSearchQuery(query)
        guard !trimmed.isEmpty else { return [] }
        let task = await searchTasks.task(for: trimmed) { [self] in
            AppLog.debug(.network, "\(config.logKey) search start query=\(trimmed)")
            if config.supportsDirectSearch {
                do {
                    let matches = try await directSearchAnime(query: trimmed)
                    AppLog.debug(.network, "\(config.logKey) direct search results count=\(matches.count)")
                    if !matches.isEmpty {
                        AppLog.debug(.network, "\(config.logKey) search success count=\(matches.count) source=direct")
                        return matches
                    }
                } catch {
                    AppLog.error(.network, "\(config.logKey) direct search failed query=\(trimmed) \(error.localizedDescription)")
                }
            }

            AppLog.debug(.network, "\(config.logKey) search fallback to luna module")
            do {
                let items = try await moduleService.search(query: trimmed)
                let matches = items.compactMap { item -> SoraAnimeMatch? in
                    guard let detailURL = URL(string: item.href) else { return nil }
                    let sessionId = detailURL.lastPathComponent
                    guard !sessionId.isEmpty else { return nil }
                    return SoraAnimeMatch(
                        id: sessionId,
                        title: item.title,
                        imageURL: URL(string: item.imageUrl),
                        session: sessionId,
                        detailURL: detailURL,
                        year: nil,
                        format: nil,
                        episodeCount: nil
                    )
                }
                AppLog.debug(.network, "\(config.logKey) luna search results count=\(matches.count)")
                if !matches.isEmpty {
                    AppLog.debug(.network, "\(config.logKey) search success count=\(matches.count) source=luna")
                    return matches
                }
            } catch {
                AppLog.error(.network, "\(config.logKey) luna search failed query=\(trimmed) \(error.localizedDescription)")
            }

            return []
        }
        defer { Task { await searchTasks.clear(trimmed) } }
        return try await task.value
    }

    private func directSearchAnime(query: String) async throws -> [SoraAnimeMatch] {
        AppLog.debug(.network, "\(config.logKey) search direct api query=\(query)")
        let url = baseURL.appendingPathComponent("api")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "m", value: "search"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: "1")
        ]
        let data = try await get(url: comps.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            let sessionId = (row["session"] as? String) ?? ""
            guard !sessionId.isEmpty else { return nil }
            let title = (row["title"] as? String) ?? "Unknown"
            let image = (row["poster"] as? String).flatMap(URL.init(string:))
            let year = row["year"] as? Int
            let format = row["type"] as? String
            let eps = row["episodes"] as? Int
            return SoraAnimeMatch(
                id: sessionId,
                title: title,
                imageURL: image,
                session: sessionId,
                detailURL: baseURL.appendingPathComponent("anime/\(sessionId)"),
                year: year,
                format: format,
                episodeCount: eps
            )
        }
    }

    func autoMatch(media: AniListMedia) async throws -> SoraAnimeMatch? {
        AppLog.debug(.matching, "auto match start mediaId=\(media.id)")
        let queries = TitleMatcher.buildQueries(for: media)
        var all: [SoraAnimeMatch] = []
        for q in queries {
            let matches = try await searchAnime(query: q)
            all.append(contentsOf: matches)
        }
        if all.isEmpty { return nil }
        let deduped = Dictionary(grouping: all, by: { $0.session })
            .compactMap { $0.value.first }
        let best = TitleMatcher.bestMatch(target: media, candidates: deduped)
        AppLog.debug(.matching, "auto match result mediaId=\(media.id) matched=\(best != nil)")
        return best
    }

    func episodes(for match: SoraAnimeMatch) async throws -> [SoraEpisode] {
        AppLog.debug(.network, "episodes list start session=\(match.session)")
        do {
            let animeURL = match.detailURL ?? baseURL.appendingPathComponent("anime/\(match.session)")
            let links = try await moduleService.episodes(animeURL: animeURL)
            AppLog.debug(.network, "episodes luna links count=\(links.count) session=\(match.session)")
            let episodes: [SoraEpisode] = links.compactMap { link in
                guard link.number > 0, !link.href.isEmpty else { return nil }
                
                let fullHref = link.href.starts(with: "/") 
                    ? baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + link.href
                    : link.href
                
                guard let playURL = URL(string: fullHref) else { return nil }
                let id = playURL.lastPathComponent
                return SoraEpisode(id: id, number: link.number, playURL: playURL)
            }
            if !episodes.isEmpty {
                let sorted = episodes.sorted { $0.number < $1.number }
                AppLog.debug(.network, "episodes list success count=\(sorted.count)")
                return sorted
            }
        } catch {
            AppLog.error(.network, "episodes luna load failed session=\(match.session) \(error.localizedDescription)")
        }

        guard config.supportsDirectEpisodes else {
            throw AniListError.invalidResponse
        }
        let sorted = try await directEpisodes(session: match.session).sorted { $0.number < $1.number }
        AppLog.debug(.network, "episodes list success count=\(sorted.count)")
        return sorted
    }

    private func directEpisodes(session: String) async throws -> [SoraEpisode] {
        AppLog.debug(.network, "episodes fallback to direct api session=\(session)")
        let url = baseURL.appendingPathComponent("api")
        var page = 1
        var out: [SoraEpisode] = []
        var lastPage = 1
        repeat {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "m", value: "release"),
                URLQueryItem(name: "id", value: session),
                URLQueryItem(name: "sort", value: "episode_asc"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            let data = try await get(url: comps.url!)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.error(.network, "episodes list decode failed session=\(session)")
                break
            }
            lastPage = root["last_page"] as? Int ?? lastPage
            let rows = (root["data"] as? [[String: Any]] ?? [])
            let eps: [SoraEpisode] = rows.compactMap { row in
                let epNumber = row["episode"] as? Int ?? 0
                let episode2 = row["episode2"] as? Int ?? 0
                let episodeSession = row["session"] as? String ?? ""
                if epNumber <= 0 || episode2 != 0 || episodeSession.isEmpty { return nil }
                let playURL = baseURL.appendingPathComponent("play/\(session)/\(episodeSession)")
                return SoraEpisode(id: episodeSession, number: epNumber, playURL: playURL)
            }
            out.append(contentsOf: eps)
            page += 1
        } while page <= lastPage
        return out
    }

    func sources(for episode: SoraEpisode) async throws -> [SoraSource] {
        AppLog.debug(.network, "sources scrape start episode=\(episode.number)")
        do {
            let result = try await moduleService.sources(episodeURL: episode.playURL)

            var sources: [SoraSource] = []
            if let sourceDicts = result.sources {
                for dict in sourceDicts {
                    if let source = sourceFromJS(dict: dict, referer: episode.playURL) {
                        sources.append(source)
                    }
                }
            } else if let urls = result.streams {
                for url in urls {
                    if let source = buildSource(urlString: url, referer: episode.playURL) {
                        sources.append(source)
                    }
                }
            }
            let deduped = dedupe(sources)
            AppLog.debug(.network, "sources luna count=\(deduped.count)")
            if !deduped.isEmpty {
                AppLog.debug(.network, "sources scrape success count=\(deduped.count)")
                return deduped
            }
        } catch {
            AppLog.error(.network, "sources luna load failed episode=\(episode.number) \(error.localizedDescription)")
        }

        // Fallback to legacy HTML scraping.
        AppLog.debug(.network, "sources fallback to html scrape episode=\(episode.number)")
        let html = try await getText(url: episode.playURL)
        let rawLinks = extractLinks(from: html)
        var sources: [SoraSource] = []
        for link in rawLinks {
            let linkString = link.absoluteString.lowercased()
            if linkString.contains("kwik.") {
                let kwikSources = try await sourcesFromKwik(url: link, referer: episode.playURL)
                sources.append(contentsOf: kwikSources)
            } else if linkString.contains(".m3u8") || linkString.contains(".mp4") {
                let src = buildSource(urlString: link.absoluteString, referer: episode.playURL)
                if let src { sources.append(src) }
            }
        }
        let deduped = dedupe(sources)
        AppLog.debug(.network, "sources scrape success count=\(deduped.count)")
        return deduped
    }

    private func sourcesFromKwik(url: URL, referer: URL) async throws -> [SoraSource] {
        AppLog.debug(.network, "kwik scrape start url=\(url.absoluteString)")
        let html = try await getText(url: url, referer: referer)
        let directLinks = extractLinks(from: html)
        var out: [SoraSource] = []
        for link in directLinks {
            let linkString = link.absoluteString.lowercased()
            if linkString.contains(".m3u8") || linkString.contains(".mp4") {
                if let source = buildSource(urlString: link.absoluteString, referer: url) {
                    out.append(source)
                }
            }
        }
        AppLog.debug(.network, "kwik scrape success count=\(out.count)")
        return out
    }

    private func buildSource(
        urlString: String,
        referer: URL,
        headers: [String: String] = [:],
        displayText: String? = nil
    ) -> SoraSource? {
        guard let url = URL(string: urlString) else { return nil }
        let quality = qualityFrom(urlString: displayText ?? urlString)
        let audio = audioLabel(from: displayText ?? urlString)
        let format = url.pathExtension.lowercased()
        let merged = mergedHeaders(headers, referer: referer)
        let metadataKey = displayText ?? urlString
        return SoraSource(
            id: "\(urlString)|\(quality)|\(audio)|\(metadataKey)|\(headerSignature(merged))",
            url: url,
            quality: quality,
            subOrDub: audio,
            format: format.isEmpty ? "m3u8" : format,
            headers: merged
        )
    }

    private func qualityFrom(urlString: String) -> String {
        if urlString.contains("1080") { return "1080p" }
        if urlString.contains("720") { return "720p" }
        if urlString.contains("360") { return "360p" }
        return "Auto"
    }

    private func audioLabel(from text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("sub") || lower.contains("jpn") || lower.contains("jp") {
            return "Sub"
        }
        if lower.contains("dub") || lower.contains("eng") || lower.contains("english") {
            return "Dub"
        }
        return "Sub"
    }

    private func sourceFromJS(dict: [String: Any], referer: URL) -> SoraSource? {
        let originalURLString = (dict["streamUrl"] as? String) ??
            (dict["url"] as? String) ??
            (dict["stream"] as? String) ??
            ""
        guard !originalURLString.isEmpty else { return nil }

        let title = (dict["title"] as? String) ?? ""
        var headers: [String: String] = [:]
        if let headerDict = dict["headers"] as? [String: Any] {
            for (key, value) in headerDict {
                headers[key] = String(describing: value)
            }
        }

        let displayText = title.isEmpty ? originalURLString : title
        return buildSource(
            urlString: originalURLString,
            referer: referer,
            headers: headers,
            displayText: displayText
        )
    }

    private func extractLinks(from html: String) -> [URL] {
        let patterns = [
            #"https?://[^"'\\s]+\.m3u8[^"'\\s]*"#,
            #"https?://[^"'\\s]+\.mp4[^"'\\s]*"#,
            #"https?://kwik\.[^"'\\s]+/e/[^"'\\s]+"#
        ]
        var links: [URL] = []
        for p in patterns {
            let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive)
            let matches = regex?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
            for match in matches {
                if let range = Range(match.range, in: html) {
                    let raw = String(html[range])
                    if let url = URL(string: raw) {
                        links.append(url)
                    }
                }
            }
        }
        return Array(Set(links))
    }

    private func dedupe(_ sources: [SoraSource]) -> [SoraSource] {
        var seen = Set<String>()
        var out: [SoraSource] = []
        for s in sources {
            let key = "\(s.id)|\(s.format)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(s)
        }
        return out
    }

    private func mergedHeaders(_ headers: [String: String], referer: URL) -> [String: String] {
        var merged = headers
        if !hasHeader("Referer", in: merged) {
            merged["Referer"] = referer.absoluteString
        }
        if !hasHeader("Origin", in: merged) {
            merged["Origin"] = "\(referer.scheme ?? "https")://\(referer.host ?? "")"
        }
        return merged
    }

    private func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func headerSignature(_ headers: [String: String]) -> String {
        headers
            .map { key, value in "\(key.lowercased())=\(value)" }
            .sorted()
            .joined(separator: "&")
    }

    private func get(url: URL, referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        } else {
            request.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader = self.cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        AppLog.debug(.network, "http get start \(url.absoluteString)")
        let (data, response) = try await self.fetch(request, label: "\(config.logKey)-get")
        self.mergeCookies(from: response)
        if let http = response as? HTTPURLResponse {
            AppLog.debug(.network, "http get response status=\(http.statusCode) bytes=\(data.count) url=\(url.absoluteString)")
        } else {
            AppLog.debug(.network, "http get response bytes=\(data.count) url=\(url.absoluteString)")
        }

        if self.shouldBypassDdos(response: response, data: data) {
            AppLog.debug(.network, "ddos bypass triggered for \(url.host ?? "")")
            try await self.performDdosBypass(targetURL: url)
            var retry = URLRequest(url: url)
            retry.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            retry.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            retry.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            retry.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            retry.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
            if let referer {
                retry.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            } else {
                retry.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Referer")
            }
            if let cookieHeader = self.cookieHeader {
                retry.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (retryData, retryResponse) = try await self.fetch(retry, label: "\(config.logKey)-get-retry")
            self.mergeCookies(from: retryResponse)
            if let http = retryResponse as? HTTPURLResponse {
                AppLog.debug(.network, "http get retry response status=\(http.statusCode) bytes=\(retryData.count) url=\(url.absoluteString)")
            } else {
                AppLog.debug(.network, "http get retry response bytes=\(retryData.count) url=\(url.absoluteString)")
            }
            return retryData
        }
        return data
    }

    private func normalizeSearchQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
    }

    private func fetch(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        return try await NetworkRetry.withRetries(label: label) { [self] in
            do {
                let (data, response) = try await self.session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 500 || http.statusCode == 429 {
                    AppLog.debug(.network, "\(label) response status=\(http.statusCode) url=\(request.url?.absoluteString ?? "")")
                    throw URLError(.badServerResponse)
                }
                return (data, response)
            } catch {
                AppLog.error(.network, "\(label) failed url=\(request.url?.absoluteString ?? "") \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func shouldBypassDdos(response: URLResponse, data: Data) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 403 { return true }
        if http.statusCode >= 400 { return true }
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else {
            return false
        }
        return text.contains("ddos-guard") ||
            text.contains("ddos-guard/js-challenge") ||
            text.contains("data-ddg-origin") ||
            text.contains("just a moment")
    }

    private func performDdosBypass(targetURL: URL) async throws {
        let checkURL = URL(string: "https://check.ddos-guard.net/check.js")!
        var req = URLRequest(url: checkURL)
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(req, label: "ddos-guard-check")
        mergeCookies(from: response)

        guard let js = String(data: data, encoding: .utf8) else { return }
        let wellKnownPath = matchFirst(
            pattern: #"['"](/\.well-known/ddos-guard/[^'"]+)['"]"#,
            in: js
        )
        let checkPath = matchFirst(
            pattern: #"['"](https://check\.ddos-guard\.net/[^'"]+)['"]"#,
            in: js
        )

        let origin = "\(targetURL.scheme ?? "https")://\(targetURL.host ?? "")"
        if let wellKnownPath {
            let url = URL(string: origin + wellKnownPath)!
            var step = URLRequest(url: url)
            step.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
            step.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            step.setValue(targetURL.absoluteString, forHTTPHeaderField: "Referer")
            if let cookieHeader {
                step.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (_, resp) = try await fetch(step, label: "ddos-guard-wellknown")
            mergeCookies(from: resp)
        }

        if let checkPath, let url = URL(string: checkPath) {
            var step = URLRequest(url: url)
            step.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
            step.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            step.setValue(targetURL.absoluteString, forHTTPHeaderField: "Referer")
            if let cookieHeader {
                step.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (_, resp) = try await fetch(step, label: "ddos-guard-checkpath")
            mergeCookies(from: resp)
        }
    }

    private func mergeCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        let headers = http.allHeaderFields
        var existing = cookieMap(from: cookieHeader)
        for (key, value) in headers {
            if let k = key as? String, k.caseInsensitiveCompare("set-cookie") == .orderedSame {
                let raw = value as? String ?? ""
                for line in raw.split(separator: ",") {
                    let first = line.split(separator: ";").first ?? ""
                    let parts = first.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let name = parts[0].trimmingCharacters(in: .whitespaces)
                        let val = parts[1].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty && !val.isEmpty {
                            existing[name] = val
                        }
                    }
                }
            }
        }
        cookieHeader = existing.isEmpty
            ? nil
            : existing.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func cookieMap(from header: String?) -> [String: String] {
        guard let header, !header.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for part in header.split(separator: ";") {
            let bits = part.split(separator: "=", maxSplits: 1)
            if bits.count == 2 {
                let name = bits[0].trimmingCharacters(in: .whitespaces)
                let val = bits[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !val.isEmpty {
                    out[name] = val
                }
            }
        }
        return out
    }

    private func matchFirst(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func getText(url: URL, referer: URL? = nil) async throws -> String {
        let data = try await get(url: url, referer: referer)
        return String(data: data, encoding: .utf8) ?? ""
    }

}

actor InFlightStringTaskStore<Value> {
    private var tasks: [String: Task<Value, Error>] = [:]

    func task(for key: String, create: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
        if let existing = tasks[key] {
            return existing
        }
        let task = Task(operation: create)
        tasks[key] = task
        return task
    }

    func clear(_ key: String) {
        tasks[key] = nil
    }
}

