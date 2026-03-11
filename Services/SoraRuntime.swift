import Foundation

final class SoraRuntime {
    private let baseURL = URL(string: "https://animepahe.com")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchAnime(query: String) async throws -> [SoraAnimeMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        AppLog.debug(.network, "animepahe search start query=\(trimmed)")
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
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
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
        guard let url = URL(string: urlString) else { return nil }
        let quality = qualityFrom(urlString: urlString)
        let audio = audioLabel(from: urlString)
        let format = url.pathExtension.lowercased()
        let headers = [
            "Referer": referer.absoluteString,
            "Origin": "\(referer.scheme ?? "https")://\(referer.host ?? "")"
        ]
        return SoraSource(
            id: "\(urlString)|\(quality)|\(audio)",
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

    private func get(url: URL, referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        AppLog.debug(.network, "http get \(url.absoluteString)")
        let (data, _) = try await session.data(for: request)
        return data
    }

    private func getText(url: URL, referer: URL? = nil) async throws -> String {
        let data = try await get(url: url, referer: referer)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

