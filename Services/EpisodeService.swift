import Foundation

enum EpisodeMatchValidationError: LocalizedError {
    case implausibleEpisodes

    var errorDescription: String? {
        switch self {
        case .implausibleEpisodes:
            return "That match looks incomplete. Try a different result."
        }
    }
}

final class EpisodeService {
    private let matchStore = MatchStore.shared
    private let tmdbMatcher: TMDBMatchingService
    private let cacheStore: CacheStore

    init(
        tmdbMatcher: TMDBMatchingService = TMDBMatchingService(cacheStore: CacheStore()),
        cacheStore: CacheStore = CacheStore()
    ) {
        self.tmdbMatcher = tmdbMatcher
        self.cacheStore = cacheStore
    }

    struct MatchLoadResult {
        let match: SoraAnimeMatch
        let episodes: [SoraEpisode]
        let isManual: Bool
    }

    private struct CachedEpisodeList: Codable {
        let match: StoredMatch
        let episodes: [SoraEpisode]
    }

    func cachedEpisodes(for media: AniListMedia) -> MatchLoadResult? {
        let moduleID = StreamingModuleStore.shared.selectedModuleID()
        let cacheKey = cachedEpisodesKey(for: media.id, moduleID: moduleID)
        guard let data = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
              let cached = try? JSONDecoder().decode(CachedEpisodeList.self, from: data),
              let match = cached.match.asSoraMatch() else {
            return nil
        }
        return MatchLoadResult(match: match, episodes: cached.episodes, isManual: cached.match.isManual)
    }

    func invalidateCachedEpisodes(for media: AniListMedia) {
        cacheStore.removeKeys(withPrefix: "episodes:v1:\(media.id):")
    }

    func loadEpisodes(media: AniListMedia) async throws -> MatchLoadResult {
        AppLog.debug(.network, "episodes load start mediaId=\(media.id)")
        let module = StreamingModuleStore.shared.currentModule()
        let provider = module.behavior
        let runtime = SoraRuntime(module: module)

        if let stored = matchStore.match(for: media.id, moduleID: module.id),
           let storedMatch = stored.asSoraMatch() {
            AppLog.debug(.matching, "using stored match mediaId=\(media.id) session=\(storedMatch.session) provider=\(provider.title) manual=\(stored.isManual)")
            do {
                let episodes = try await runtime.episodes(for: storedMatch)
                let adjusted = await applySeasonOffsetIfNeeded(episodes: episodes, media: media, provider: provider)
                if isPlausibleEpisodeMatch(match: storedMatch, episodes: adjusted, media: media, provider: provider) {
                    AppLog.debug(.network, "episodes load success mediaId=\(media.id) count=\(adjusted.count)")
                    let result = MatchLoadResult(match: storedMatch, episodes: adjusted, isManual: stored.isManual)
                    cache(result: result, mediaId: media.id, moduleID: module.id, behavior: provider)
                    return result
                }

                AppLog.debug(.matching, "stored match rejected mediaId=\(media.id) session=\(storedMatch.session) manual=\(stored.isManual) count=\(adjusted.count)")
                matchStore.clear(mediaId: media.id)
                invalidateCachedEpisodes(for: media)
                return try await loadAutoMatchedEpisodes(media: media, runtime: runtime, moduleID: module.id, provider: provider, replaceExisting: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.error(.network, "stored match episodes failed mediaId=\(media.id) session=\(storedMatch.session) \(error.localizedDescription)")
                if Task.isCancelled {
                    throw CancellationError()
                }
                matchStore.clear(mediaId: media.id)
                invalidateCachedEpisodes(for: media)
                return try await loadAutoMatchedEpisodes(media: media, runtime: runtime, moduleID: module.id, provider: provider, replaceExisting: false)
            }
        }

        return try await loadAutoMatchedEpisodes(media: media, runtime: runtime, moduleID: module.id, provider: provider, replaceExisting: true)
    }

    private func loadAutoMatchedEpisodes(
        media: AniListMedia,
        runtime: SoraRuntime,
        moduleID: String,
        provider: StreamingProvider,
        replaceExisting: Bool
    ) async throws -> MatchLoadResult {
        if replaceExisting == false {
            AppLog.debug(.matching, "stored match fallback to auto mediaId=\(media.id) provider=\(provider.title)")
        }

        let rankedCandidates = try await autoMatchedCandidates(for: media, runtime: runtime, provider: provider)
        guard !rankedCandidates.isEmpty else {
            AppLog.error(.network, "episodes auto match failed mediaId=\(media.id)")
            throw AniListError.invalidResponse
        }

        let probeLimit: Int
        let isReleasing = (media.status ?? "").uppercased() == "RELEASING"
        if provider == .animeKai {
            let topScore = rankedCandidates.first?.matchScore ?? 0
            probeLimit = topScore >= 0.94 ? min(rankedCandidates.count, 2) : min(rankedCandidates.count, 4)
        } else if provider == .animePahe {
            let topScore = rankedCandidates.first?.matchScore ?? 0
            if isReleasing {
                probeLimit = topScore >= 0.97 ? min(rankedCandidates.count, 3) : min(rankedCandidates.count, 5)
            } else {
                probeLimit = topScore >= 0.95 ? 1 : min(rankedCandidates.count, 3)
            }
        } else {
            probeLimit = 1
        }
        for match in rankedCandidates.prefix(probeLimit) {
            do {
                let episodes = try await runtime.episodes(for: match)
                let adjusted = await applySeasonOffsetIfNeeded(episodes: episodes, media: media, provider: provider)
                guard isPlausibleEpisodeMatch(match: match, episodes: adjusted, media: media, provider: provider) else {
                    AppLog.debug(.matching, "auto match candidate rejected mediaId=\(media.id) session=\(match.session) provider=\(provider.title) count=\(adjusted.count) score=\(match.matchScore ?? 0)")
                    continue
                }
                matchStore.set(match: match, mediaId: media.id, isManual: false, moduleID: moduleID, behavior: provider)
                AppLog.debug(.network, "episodes load success mediaId=\(media.id) count=\(adjusted.count)")
                let result = MatchLoadResult(match: match, episodes: adjusted, isManual: false)
                cache(result: result, mediaId: media.id, moduleID: moduleID, behavior: provider)
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.error(.network, "auto match candidate failed mediaId=\(media.id) session=\(match.session) \(error.localizedDescription)")
            }
        }

        AppLog.error(.network, "episodes auto match failed mediaId=\(media.id)")
        throw AniListError.invalidResponse
    }

    func loadSources(for episode: SoraEpisode) async throws -> [SoraSource] {
        AppLog.debug(.network, "sources load start episode=\(episode.number)")
        let runtime = SoraRuntime(module: StreamingModuleStore.shared.currentModule())
        let sources = try await runtime.sources(for: episode)
        AppLog.debug(.network, "sources load success count=\(sources.count)")
        return sources
    }

    func searchCandidates(media: AniListMedia) async throws -> [SoraAnimeMatch] {
        let module = StreamingModuleStore.shared.currentModule()
        let provider = module.behavior
        let runtime = SoraRuntime(module: module)
        let queries = TitleMatcher.buildQueries(for: media)
        AppLog.debug(.matching, "manual match search start mediaId=\(media.id) queries=\(queries.count)")
        var all: [SoraAnimeMatch] = []
        for q in queries {
            let matches = try await runtime.searchAnime(query: q)
            all.append(contentsOf: matches)
        }
        let ranked = rankCandidates(all, media: media, provider: provider)
        let deduped = TitleMatcher.dedupeCandidates(ranked, provider: provider)
        AppLog.debug(.matching, "manual match search complete mediaId=\(media.id) candidates=\(deduped.count)")
        return deduped
    }

    func searchCandidates(query: String, media: AniListMedia? = nil) async throws -> [SoraAnimeMatch] {
        let module = StreamingModuleStore.shared.currentModule()
        let provider = module.behavior
        let runtime = SoraRuntime(module: module)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        AppLog.debug(.matching, "manual match search start query=\(trimmed)")
        let matches = try await runtime.searchAnime(query: trimmed)
        let ranked = rankCandidates(matches, media: media, provider: provider)
        let deduped = TitleMatcher.dedupeCandidates(ranked, provider: provider)
        AppLog.debug(.matching, "manual match search complete query=\(trimmed) candidates=\(deduped.count)")
        return deduped
    }

    func setManualMatch(media: AniListMedia, match: SoraAnimeMatch) {
        let module = StreamingModuleStore.shared.currentModule()
        matchStore.set(match: match, mediaId: media.id, isManual: true, moduleID: module.id, behavior: module.behavior)
    }

    func applyManualMatch(media: AniListMedia, match: SoraAnimeMatch) async throws -> MatchLoadResult {
        let module = StreamingModuleStore.shared.currentModule()
        let provider = module.behavior
        let runtime = SoraRuntime(module: module)
        let episodes = try await runtime.episodes(for: match)
        let adjusted = await applySeasonOffsetIfNeeded(episodes: episodes, media: media, provider: provider)
        guard isPlausibleEpisodeMatch(
            match: match,
            episodes: adjusted,
            media: media,
            provider: provider,
            allowPartialManualMatch: true
        ) else {
            AppLog.debug(.matching, "manual match rejected mediaId=\(media.id) session=\(match.session) provider=\(provider.title) count=\(adjusted.count)")
            throw EpisodeMatchValidationError.implausibleEpisodes
        }
        matchStore.set(match: match, mediaId: media.id, isManual: true, moduleID: module.id, behavior: provider)
        AppLog.debug(.network, "manual match validated mediaId=\(media.id) session=\(match.session) count=\(adjusted.count)")
        let result = MatchLoadResult(match: match, episodes: adjusted, isManual: true)
        cache(result: result, mediaId: media.id, moduleID: module.id, behavior: provider)
        return result
    }

    func clearManualMatch(media: AniListMedia) {
        matchStore.clear(mediaId: media.id)
        invalidateCachedEpisodes(for: media)
    }

    private func cache(
        result: MatchLoadResult,
        mediaId: Int,
        moduleID: String,
        behavior: StreamingProvider
    ) {
        let stored = StoredMatch(
            mediaId: mediaId,
            session: result.match.session,
            title: result.match.title,
            imageURL: result.match.imageURL?.absoluteString,
            detailURL: result.match.detailURL?.absoluteString,
            year: result.match.year,
            format: result.match.format,
            episodeCount: result.match.episodeCount,
            provider: behavior.rawValue,
            moduleID: moduleID,
            isManual: result.isManual,
            updatedAt: Date().timeIntervalSince1970
        )
        let payload = CachedEpisodeList(match: stored, episodes: result.episodes)
        if let data = try? JSONEncoder().encode(payload) {
            cacheStore.writeJSON(data, forKey: cachedEpisodesKey(for: mediaId, moduleID: moduleID))
        }
    }

    private func cachedEpisodesKey(for mediaId: Int, moduleID: String) -> String {
        "episodes:v1:\(mediaId):module:\(moduleID)"
    }

    private func applySeasonOffsetIfNeeded(
        episodes: [SoraEpisode],
        media: AniListMedia,
        provider: StreamingProvider
    ) async -> [SoraEpisode] {
        guard !episodes.isEmpty else { return episodes }

        let sorted = episodes.sorted { lhs, rhs in
            if lhs.sourceNumber == rhs.sourceNumber {
                return lhs.id < rhs.id
            }
            return lhs.sourceNumber < rhs.sourceNumber
        }
        let expected = media.episodes ?? 0
        let rawMin = sorted.first?.sourceNumber ?? 1
        let rawMax = sorted.last?.sourceNumber ?? rawMin
        let seasonMarker = TitleMatcher.extractSeasonMarkerNumber(from: media.title.best) ?? 1
        let hasPartMarker = TitleMatcher.extractPartMarkerNumber(from: media.title.best) != nil
        let looksSeasonLocal =
            rawMin == 1 &&
            seasonMarker <= 1 &&
            !hasPartMarker &&
            (expected == 0 || (sorted.count >= expected && rawMax <= max(expected, rawMin)))

        if looksSeasonLocal {
            AppLog.debug(.matching, "ani.zip/TMDB shaping skipped mediaId=\(media.id) provider=\(provider.title) reason=season-local")
            return sorted.map {
                SoraEpisode(id: $0.id, sourceNumber: $0.sourceNumber, displayNumber: $0.sourceNumber, playURL: $0.playURL)
            }
        }

        // Tier 1: Ani.zip (most accurate for anime)
        if let aniZipInfo = await AniZipClient.getSeasonInfo(aniListId: media.id),
           let episodes = aniZipInfo.episodes, !episodes.isEmpty,
           expected > 0 {
            let aniZipOffset = calculateOffsetFromAniZip(episodes: episodes)
            if aniZipOffset > 0 {
                let seasonStart = aniZipOffset + 1
                let canApplyAniZipSlice =
                    seasonStart > 1 &&
                    rawMin == 1 &&
                    rawMax >= seasonStart &&
                    sorted.count > aniZipOffset

                if canApplyAniZipSlice {
                    let slice = Array(sorted.dropFirst(aniZipOffset).prefix(expected))
                    if !slice.isEmpty {
                        AppLog.debug(.matching, "ani.zip season offset applied mediaId=\(media.id) offset=\(aniZipOffset) count=\(slice.count)")
                        return enumerateDisplayNumbers(slice)
                    }
                }
            }
        }

        // Tier 2: TMDB matching (fallback if ani.zip doesn't provide offset)
        // Only use TMDB for season-local slicing. Absolute franchise offsets can hide
        // valid AnimePahe episode lists when the provider already points at a season page.
        let tmdbMatch = await withThrowingTaskGroup(of: TMDBSeasonMatch?.self) { group in
            group.addTask {
                await self.tmdbMatcher.matchShowAndSeason(media: media)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                return nil
            }
            return (try? await group.next()!) ?? nil
        }

        if let tmdbMatch, expected > 0 {
            let offset = tmdbMatch.episodeOffset
            let seasonStart = offset + 1
            let canApplySeasonSlice =
                seasonStart > 1 &&
                rawMin == 1 &&
                rawMax >= seasonStart &&
                sorted.count > offset

            if canApplySeasonSlice {
                let slice = Array(sorted.dropFirst(offset).prefix(expected))
                if !slice.isEmpty {
                    AppLog.debug(.matching, "TMDB season-local offset applied mediaId=\(media.id) season=\(tmdbMatch.seasonNumber) offset=\(offset) count=\(slice.count)")
                    return enumerateDisplayNumbers(slice)
                }
            } else if offset > 0 {
                AppLog.debug(.matching, "TMDB offset skipped for episode shaping mediaId=\(media.id) season=\(tmdbMatch.seasonNumber) offset=\(offset) min=\(rawMin) max=\(rawMax)")
            }
        }

        // Tier 3: Heuristic slicing if TMDB/ani.zip fails or offset is 0

        if expected > 0, seasonMarker > 1, rawMin == 1 {
            let offset = expected * (seasonMarker - 1)
            if sorted.count > offset {
                let slice = Array(sorted.dropFirst(offset).prefix(expected))
                if !slice.isEmpty {
                    AppLog.debug(.matching, "Heuristic season offset applied mediaId=\(media.id) season=\(seasonMarker) offset=\(offset)")
                    return enumerateDisplayNumbers(slice)
                }
            }
        }

        if expected > 0 {
            let needsRenumber = rawMin > 1 || rawMax > expected || hasPartMarker
            if needsRenumber {
                AppLog.debug(.matching, "episode renumber applied mediaId=\(media.id) min=\(rawMin) max=\(rawMax) expected=\(expected)")
                return enumerateDisplayNumbers(sorted)
            }
        } else if rawMin > 1 {
            return enumerateDisplayNumbers(sorted)
        }

        return sorted.map {
            SoraEpisode(id: $0.id, sourceNumber: $0.sourceNumber, displayNumber: $0.sourceNumber, playURL: $0.playURL)
        }
    }

    private func calculateOffsetFromAniZip(episodes: [String: AniZipEpisode]) -> Int {
        var maxOffset = 0
        for (_, episode) in episodes {
            if let absNum = episode.absoluteEpisodeNumber, let epNum = episode.episodeNumber {
                let offset = absNum - epNum
                maxOffset = max(maxOffset, offset)
            }
        }
        return maxOffset
    }

    private func enumerateDisplayNumbers(_ episodes: [SoraEpisode]) -> [SoraEpisode] {
        episodes.enumerated().map { index, episode in
            SoraEpisode(
                id: episode.id,
                sourceNumber: episode.sourceNumber,
                displayNumber: index + 1,
                playURL: episode.playURL
            )
        }
    }

    private func rankCandidates(
        _ candidates: [SoraAnimeMatch],
        media: AniListMedia?,
        provider: StreamingProvider
    ) -> [SoraAnimeMatch] {
        guard let media else {
            return TitleMatcher.dedupeCandidates(candidates, provider: provider)
        }
        return TitleMatcher.rankedCandidates(target: media, candidates: candidates, provider: provider)
    }

    private func autoMatchedCandidates(
        for media: AniListMedia,
        runtime: SoraRuntime,
        provider: StreamingProvider
    ) async throws -> [SoraAnimeMatch] {
        let queries = TitleMatcher.buildQueries(for: media)
        var all: [SoraAnimeMatch] = []
        for query in queries {
            let matches = try await runtime.searchAnime(query: query)
            all.append(contentsOf: matches)
        }
        let ranked = TitleMatcher.rankedCandidates(target: media, candidates: all, provider: provider)
        return TitleMatcher.dedupeCandidates(ranked, provider: provider)
    }

    private func isPlausibleEpisodeMatch(
        match: SoraAnimeMatch,
        episodes: [SoraEpisode],
        media: AniListMedia,
        provider: StreamingProvider,
        allowPartialManualMatch: Bool = false
    ) -> Bool {
        guard !episodes.isEmpty else { return false }
        guard provider == .animeKai else { return true }

        if allowPartialManualMatch {
            return true
        }

        let isReleasing = (media.status ?? "").uppercased() == "RELEASING"
        if isReleasing {
            return !episodes.isEmpty
        }

        let expected = max(media.episodes ?? 0, match.episodeCount ?? 0)
        if expected <= 1 {
            return !episodes.isEmpty
        }

        if episodes.count == 1 {
            return false
        }

        if expected >= 8 && episodes.count <= 2 {
            return false
        }

        return true
    }
}
