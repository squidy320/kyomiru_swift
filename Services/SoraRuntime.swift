import Foundation

final class SoraRuntime {
    private let baseURL = URL(string: "https://animepahe.si")!
    private let session: URLSession
    private var cookieHeader: String?
    private let js = JSController.shared
    private let manifestURL = URL(string: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.json")!
    private var loadedService: Service?
    private var loadedAt: Date?

    init(session: URLSession = .custom) {
        self.session = session
    }

    func searchAnime(query: String) async throws -> [SoraAnimeMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        AppLog.debug(.network, "animepahe search start query=\(trimmed)")
        do {
            let service = try await loadServiceIfNeeded()
            AppLog.debug(.network, "animepahe search using luna manifest=\(manifestURL.absoluteString)")
            let items: [SearchItem] = await withCheckedContinuation { cont in
                js.fetchJsSearchResults(keyword: trimmed, module: service) { results in
                    cont.resume(returning: results)
                }
            }
            let matches = items.compactMap { item -> SoraAnimeMatch? in
                let sessionId = URL(string: item.href)?.lastPathComponent ?? ""
                guard !sessionId.isEmpty else { return nil }
                return SoraAnimeMatch(
                    id: sessionId,
                    title: item.title,
                    imageURL: URL(string: item.imageUrl),
                    session: sessionId,
                    year: nil,
                    format: nil,
                    episodeCount: nil
                )
            }
            AppLog.debug(.network, "animepahe luna search results count=\(matches.count)")
            if !matches.isEmpty {
                AppLog.debug(.network, "animepahe search success count=\(matches.count)")
                return matches
            }
        } catch {
            AppLog.error(.network, "animepahe luna search failed query=\(trimmed) \(error.localizedDescription)")
        }

        // Fallback to direct API when JS loader fails.
        AppLog.debug(.network, "animepahe search fallback to direct api")
        let url = baseURL.appendingPathComponent("api")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "m", value: "search"),
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "page", value: "1")
        ]
        let data = try await get(url: comps.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        let matches: [SoraAnimeMatch] = list.compactMap { (row: [String: Any]) -> SoraAnimeMatch? in
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
                year: year,
                format: format,
                episodeCount: eps
            )
        }
        AppLog.debug(.network, "animepahe search success count=\(matches.count)")
        return matches
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
            _ = try await loadServiceIfNeeded()
            let animeURL = baseURL.appendingPathComponent("anime/\(match.session)")
            let links: [EpisodeLink] = await withCheckedContinuation { cont in
                js.fetchEpisodesJS(url: animeURL.absoluteString) { results in
                    cont.resume(returning: results)
                }
            }
            AppLog.debug(.network, "episodes luna links count=\(links.count) session=\(match.session)")
            let episodes: [SoraEpisode] = links.compactMap { link in
                guard link.number > 0 else { return nil }
                let href = link.href.isEmpty ? animeURL.absoluteString : link.href
                guard let playURL = URL(string: href) else { return nil }
                let id = URL(string: href)?.lastPathComponent ?? UUID().uuidString
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

        // Fallback to direct API when JS loader fails.
        AppLog.debug(.network, "episodes fallback to direct api session=\(match.session)")
        let url = baseURL.appendingPathComponent("api")
        var page = 1
        var out: [SoraEpisode] = []
        var lastPage = 1
        repeat {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "m", value: "release"),
                URLQueryItem(name: "id", value: match.session),
                URLQueryItem(name: "sort", value: "episode_asc"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            let data = try await get(url: comps.url!)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.error(.network, "episodes list decode failed session=\(match.session)")
                break
            }
            lastPage = root["last_page"] as? Int ?? lastPage
            let rows = (root["data"] as? [[String: Any]] ?? [])
            let eps: [SoraEpisode] = rows.compactMap { row in
                let epNumber = row["episode"] as? Int ?? 0
                let episode2 = row["episode2"] as? Int ?? 0
                let session = row["session"] as? String ?? ""
                if epNumber <= 0 || episode2 != 0 || session.isEmpty { return nil }
                let playURL = baseURL.appendingPathComponent("play/\(match.session)/\(session)")
                return SoraEpisode(id: session, number: epNumber, playURL: playURL)
            }
            out.append(contentsOf: eps)
            page += 1
        } while page <= lastPage
        let sorted = out.sorted { $0.number < $1.number }
        AppLog.debug(.network, "episodes list success count=\(sorted.count)")
        return sorted
    }

    func sources(for episode: SoraEpisode) async throws -> [SoraSource] {
        AppLog.debug(.network, "sources scrape start episode=\(episode.number)")
        do {
            let service = try await loadServiceIfNeeded()
            let result = await withCheckedContinuation { cont in
                js.fetchStreamUrlJS(episodeUrl: episode.playURL.absoluteString, module: service) { result in
                    cont.resume(returning: result)
                }
            }

            var sources: [SoraSource] = []
            if let sourceDicts = result.sources {
                for dict in sourceDicts {
                    if let source = sourceFromJS(dict: dict, referer: episode.playURL) {
                        sources.append(source)
                    }
                }
            } else if let urls = result.streams {
                for url in urls {
                    if let src = buildSource(urlString: url, referer: episode.playURL) {
                        sources.append(src)
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
                if let src = buildSource(urlString: link.absoluteString, referer: url) {
                    out.append(src)
                }
            }
        }
        AppLog.debug(.network, "kwik scrape success count=\(out.count)")
        return out
    }

    private func buildSource(urlString: String, referer: URL) -> SoraSource? {
        let preferredURLString = preferredAnimePaheStreamURLString(from: urlString)
        guard let url = URL(string: preferredURLString) else { return nil }
        let quality = qualityFrom(urlString: preferredURLString)
        let audio = audioLabel(from: preferredURLString)
        let format = url.pathExtension.lowercased()
        let headers = [
            "Referer": referer.absoluteString,
            "Origin": "\(referer.scheme ?? "https")://\(referer.host ?? "")"
        ]
        return SoraSource(
            id: "\(preferredURLString)|\(quality)|\(audio)",
            url: url,
            quality: quality,
            subOrDub: audio,
            format: format.isEmpty ? "m3u8" : format,
            headers: headers
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
        let urlString = preferredAnimePaheStreamURLString(from: originalURLString)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }

        let title = (dict["title"] as? String) ?? ""
        let quality = qualityFrom(urlString: title.isEmpty ? urlString : title)
        let audio = audioLabel(from: title.isEmpty ? urlString : title)
        let format = url.pathExtension.isEmpty ? "m3u8" : url.pathExtension.lowercased()

        var headers: [String: String] = [
            "Referer": referer.absoluteString,
            "Origin": "\(referer.scheme ?? "https")://\(referer.host ?? "")"
        ]
        if let headerDict = dict["headers"] as? [String: Any] {
            for (key, value) in headerDict {
                headers[key] = String(describing: value)
            }
        }

        return SoraSource(
            id: "\(urlString)|\(quality)|\(audio)",
            url: url,
            quality: quality,
            subOrDub: audio,
            format: format,
            headers: headers
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
            let key = "\(s.url.absoluteString)|\(s.quality)|\(s.subOrDub)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(s)
        }
        return out
    }

    private func preferredAnimePaheStreamURLString(from urlString: String) -> String {
        guard
            let components = URLComponents(string: urlString),
            let host = components.host?.lowercased(),
            host.contains("owocdn"),
            components.path.lowercased().hasSuffix("/uwu.m3u8")
        else {
            return urlString
        }

        return urlString.replacingOccurrences(of: "/uwu.m3u8", with: "/owo.m3u8")
    }

    private func get(url: URL, referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        } else {
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        AppLog.debug(.network, "http get \(url.absoluteString)")
        let (data, response) = try await fetch(request, label: "animepahe-get")
        mergeCookies(from: response)

        if shouldBypassDdos(response: response, data: data) {
            try await performDdosBypass(targetURL: url)
            var retry = URLRequest(url: url)
            retry.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            retry.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            retry.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            retry.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            retry.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
            if let referer {
                retry.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            } else {
                retry.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
            }
            if let cookieHeader {
                retry.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (retryData, retryResponse) = try await fetch(retry, label: "animepahe-get-retry")
            mergeCookies(from: retryResponse)
            return retryData
        }

        return data
    }

    private func fetch(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        return try await NetworkRetry.withRetries(label: label) { [self] in
            let (data, response) = try await self.session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 || http.statusCode == 429 {
                throw URLError(.badServerResponse)
            }
            return (data, response)
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

    private func loadServiceIfNeeded() async throws -> Service {
        let now = Date()
        if let service = loadedService,
           let loadedAt,
           now.timeIntervalSince(loadedAt) < 1800 {
            AppLog.debug(.network, "luna service cache hit")
            return service
        }

        AppLog.debug(.network, "luna manifest load start url=\(manifestURL.absoluteString)")
        var manifestRequest = URLRequest(url: manifestURL)
        manifestRequest.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        manifestRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (manifestData, _) = try await fetch(manifestRequest, label: "luna-manifest")
        let metadata = try JSONDecoder().decode(ServiceMetadata.self, from: manifestData)
        AppLog.debug(.network, "luna manifest loaded name=\(metadata.sourceName) version=\(metadata.version)")
        guard let scriptURL = URL(string: metadata.scriptUrl) else {
            throw URLError(.badURL)
        }
        var scriptRequest = URLRequest(url: scriptURL)
        scriptRequest.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        scriptRequest.setValue("text/javascript,*/*", forHTTPHeaderField: "Accept")
        let (scriptData, _) = try await fetch(scriptRequest, label: "luna-script")
        var script = String(data: scriptData, encoding: .utf8) ?? ""
        if script.isEmpty {
            throw URLError(.cannotDecodeContentData)
        }
        // JSCore on some builds struggles with the dotAll "s" flag; normalize a few known patterns.
        script = script
            .replacingOccurrences(
                of: "match(/<div class=\"anime-synopsis\">(.*?)<\\/div>/s)",
                with: "match(/<div class=\\\"anime-synopsis\\\">([\\s\\S]*?)<\\/div>/)"
            )
            .replacingOccurrences(
                of: "match(/<strong>Aired:<\\/strong>(.*?)<\\/p>/s)",
                with: "match(/<strong>Aired:<\\/strong>([\\s\\S]*?)<\\/p>/)"
            )
            .replacingOccurrences(
                of: "match(/<script>(.*?)<\\/script>/s)",
                with: "match(/<script>([\\s\\S]*?)<\\/script>/)"
            )
        AppLog.debug(.network, "luna script loaded size=\(script.count)")

        let service = Service(
            id: UUID(),
            metadata: metadata,
            jsScript: script,
            url: manifestURL.absoluteString,
            isActive: true,
            sortIndex: 0
        )
        loadedService = service
        loadedAt = now
        js.loadScript(script)
        AppLog.debug(.network, "luna script loaded into JSContext")
        return service
    }
}

