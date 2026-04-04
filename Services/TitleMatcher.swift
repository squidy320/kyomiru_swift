import Foundation

enum TitleMatcher {
    struct RankedCandidate {
        let match: SoraAnimeMatch
        let score: Double
        let normalizedTitle: String
        let context: String?
    }

    static func bestMatch(
        target: AniListMedia,
        candidates: [SoraAnimeMatch],
        provider: StreamingProvider = .current
    ) -> SoraAnimeMatch? {
        AppLog.debug(.matching, "best match start provider=\(provider.rawValue) mediaId=\(target.id) mediaTitle='\(target.title.best)' candidates=\(candidates.count)")
        let ranked = rankedCandidateEntries(target: target, candidates: candidates, provider: provider)
        
        for (index, entry) in ranked.prefix(5).enumerated() {
            AppLog.debug(.matching, "  #\(index+1) candidate='\(entry.match.title)' score=\(String(format: "%.4f", entry.score)) context='\(entry.context ?? "")'")
        }
        
        let best = ranked.first?.match
        AppLog.debug(.matching, "best match result mediaId=\(target.id) matched='\(best?.title ?? "nil")'")
        return best
    }

    static func rankedCandidates(
        target: AniListMedia,
        candidates: [SoraAnimeMatch],
        provider: StreamingProvider = .current
    ) -> [SoraAnimeMatch] {
        rankedCandidateEntries(target: target, candidates: candidates, provider: provider).map(\.match)
    }

    static func rankedCandidateEntries(
        target: AniListMedia,
        candidates: [SoraAnimeMatch],
        provider: StreamingProvider = .current
    ) -> [RankedCandidate] {
        let targetTitle = target.title.best
        let wantedSeason = extractSeasonNumber(from: targetTitle)
        let normalizedTarget = normalizedTitle(targetTitle, provider: provider)
        let normalizedTargetBase = stripSequenceMarkers(from: normalizedTarget, provider: provider)
        let targetYear = target.seasonYear
        let targetFormat = target.format ?? target.status
        let queries = buildQueries(for: target).map { normalizedTitle($0, provider: provider) }

        return candidates.map { candidate in
            let ranked = rankedCandidate(
                candidate: candidate,
                normalizedTarget: normalizedTarget,
                normalizedTargetBase: normalizedTargetBase,
                wantedSeason: wantedSeason,
                targetYear: targetYear,
                targetFormat: targetFormat,
                provider: provider,
                normalizedQueries: queries
            )
            return ranked
        }
        .sorted { lhs, rhs in
            // Strongly prioritize the highest score.
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.match.title.localizedCaseInsensitiveCompare(rhs.match.title) == .orderedAscending
        }
    }

    static func score(
        candidate: SoraAnimeMatch,
        normalizedTarget: String,
        wantedSeason: Int?,
        targetYear: Int?,
        targetFormat: String?,
        provider: StreamingProvider = .current
    ) -> Double {
        let titleScore = titleSimilarity(
            candidateTitle: candidate.title,
            normalizedTarget: normalizedTarget,
            provider: provider
        )
        
        var yearScore = 0.5
        if let targetYear, let candidateYear = candidate.year {
            if targetYear == candidateYear {
                yearScore = 1.0
            } else if abs(targetYear - candidateYear) == 1 {
                yearScore = 0.7
            } else {
                yearScore = 0.0
            }
        }
        
        var formatScore = 0.5
        if let targetFormat, let candidateFormat = candidate.format {
            let t = targetFormat.lowercased()
            let c = candidateFormat.lowercased()
            let tIsMovie = t.contains("movie")
            let cIsMovie = c.contains("movie")
            let tIsSpecial = t.contains("special") || t.contains("ova") || t.contains("ona")
            let cIsSpecial = c.contains("special") || c.contains("ova") || c.contains("ona")
            
            if tIsMovie == cIsMovie && tIsSpecial == cIsSpecial {
                formatScore = 1.0
            } else if tIsMovie != cIsMovie || tIsSpecial != cIsSpecial {
                formatScore = 0.0
            }
        }
        
        var score = (0.5 * titleScore) + (0.3 * yearScore) + (0.2 * formatScore)

        let candidateSeason = extractSeasonNumber(from: candidate.title)
        let candidatePart = extractPartOnlyMarkerNumber(from: candidate.title)
        let targetPart = extractPartOnlyMarkerNumber(from: normalizedTarget)

        if let wantedSeason {
            if candidateSeason == wantedSeason {
                score += 0.20 // Increased bonus
            } else if let cs = candidateSeason, cs != wantedSeason {
                score -= 0.40 // Heavier penalty
            } else if wantedSeason == 1 {
                score += 0.08
            } else {
                score -= 0.15 // Penalty for missing season info when we know we want S2+
            }
        }
        
        // Bonus/Penalty for "Part" match
        if let targetPart {
            if candidatePart == targetPart {
                score += 0.10
            } else if let cp = candidatePart, cp != targetPart {
                score -= 0.25
            }
        } else if candidatePart != nil {
            // Target has no part, but candidate does -> likely wrong
            score -= 0.10
        }

        if provider == .animeKai || provider == .animePahe {
            let normalizedCandidate = normalizedTitle(candidate.title, provider: provider)
            let candidateBase = stripSequenceMarkers(from: normalizedCandidate, provider: provider)
            let targetBase = stripSequenceMarkers(from: normalizedTarget, provider: provider)
            
            let exactBonus = provider == .animePahe ? 0.16 : 0.20
            let baseBonus = provider == .animePahe ? 0.10 : 0.12
            
            if normalizedCandidate == normalizedTarget {
                score += exactBonus
            } else if candidateBase == targetBase {
                score += baseBonus
            }

            let baseTokens = Set(targetBase.split(separator: " ").map(String.init))
            let candidateTokens = Set(candidateBase.split(separator: " ").map(String.init))
            if !baseTokens.isEmpty {
                let overlap = Double(baseTokens.intersection(candidateTokens).count) / Double(baseTokens.count)
                score += overlap * 0.12
            }

            let targetCoreTokens = coreAnimeKaiTokens(from: targetBase)
            let candidateCoreTokens = coreAnimeKaiTokens(from: candidateBase)
            if !targetCoreTokens.isEmpty {
                let missingCoreCount = targetCoreTokens.subtracting(candidateCoreTokens).count
                let missingCoreRatio = Double(missingCoreCount) / Double(targetCoreTokens.count)
                score -= missingCoreRatio * 0.25 // Heavy penalty for missing core words
                if missingCoreCount == 0 {
                    score += 0.05
                }
            }

            if hasFinalSeasonMarker(normalizedTarget) && hasFinalSeasonMarker(candidate.title) {
                score += 0.10
            }
        }

        return min(max(score, 0.0), 1.0)
    }

    static func buildQueries(for media: AniListMedia) -> [String] {
        let titles = [
            media.title.romaji,
            media.title.english,
            media.title.native,
            media.title.best,
        ].compactMap { $0 }
        let queries = titles.flatMap(buildQueries)
        return stableUniqueQueries(queries)
    }

    static func buildQueries(from title: String) -> [String] {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return [] }
        let cleanedSeason = stripSeasonMarkers(raw)
        let finalSeasonRemoved = stripFinalSeasonMarkers(raw)
        let noTrailing = raw.replacingOccurrences(
            of: #"(?i)\b(cour|part|season)\s*\d+\b"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let romanNormalized = romanToArabic(raw)
        let romanFinalRemoved = stripFinalSeasonMarkers(romanNormalized)
        let preferred = [
            noTrailing,
            cleanedSeason,
            finalSeasonRemoved,
            stripSeasonMarkers(finalSeasonRemoved),
            stripSeasonMarkers(romanNormalized),
            romanFinalRemoved,
            stripSeasonMarkers(romanFinalRemoved),
            romanNormalized,
            raw
        ]
        return stableUniqueQueries(preferred)
    }

    static func stripSeasonMarkers(_ input: String) -> String {
        var out = input
        let patterns = [
            #"(?i)\bseason\s*\d+\b"#,
            #"(?i)\bs\s*\d+\b"#,
            #"(?i)\bpart\s*\d+\b"#,
            #"(?i)\bcour\s*\d+\b"#,
            #"(?i)\b\d+(st|nd|rd|th)\s*season\b"#
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractSeasonNumber(from input: String) -> Int? {
        if let season = extractSeasonMarkerNumber(from: input) {
            return season
        }
        // Fallback to part marker ONLY if no season marker is found
        return extractPartMarkerNumber(from: input)
    }

    static func extractSeasonMarkerNumber(from input: String) -> Int? {
        extractMarkerNumber(from: input, patterns: [
            #"(?i)\bseason\s*(\d+)\b"#,
            #"(?i)\bs\s*(\d+)\b"#,
            #"(?i)\b(\d+)(st|nd|rd|th)\s*season\b"#,
            #"(?i)season\s*([ivx]+)\b"#
        ])
    }

    static func extractPartMarkerNumber(from input: String) -> Int? {
        extractMarkerNumber(from: input, patterns: [
            #"(?i)\bpart\s*(\d+)\b"#,
            #"(?i)\bcour\s*(\d+)\b"#,
            #"(?i)part\s*([ivx]+)\b"#,
            #"(?i)cour\s*([ivx]+)\b"#
        ])
    }

    static func extractPartOnlyMarkerNumber(from input: String) -> Int? {
        extractMarkerNumber(from: input, patterns: [
            #"(?i)\bpart\s*(\d+)\b"#
        ])
    }

    static func extractCourMarkerNumber(from input: String) -> Int? {
        extractMarkerNumber(from: input, patterns: [
            #"(?i)\bcour\s*(\d+)\b"#
        ])
    }

    static func hasFinalSeasonMarker(_ input: String) -> Bool {
        let normalized = romanToArabic(input)
        return normalized.range(
            of: #"(?i)\b(?:the\s+)?final\s+season\b"#,
            options: .regularExpression
        ) != nil
    }

    static func stripFinalSeasonMarkers(_ input: String) -> String {
        input.replacingOccurrences(
            of: #"(?i)\b(?:the\s+)?final\s+season\b"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanTitle(_ input: String) -> String {
        var out = input
        out = romanToArabic(out)
        out = out.lowercased()
        out = out.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\b(tv|anime)\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTitle(_ input: String, provider: StreamingProvider = .current) -> String {
        switch provider {
        case .animePahe:
            return cleanTitle(stripSeasonMarkers(input))
        case .animeKai:
            return cleanAnimeKaiTitle(input)
        }
    }

    static func dedupeCandidates(
        _ candidates: [SoraAnimeMatch],
        provider: StreamingProvider = .current
    ) -> [SoraAnimeMatch] {
        switch provider {
        case .animePahe:
            let deduped = Dictionary(grouping: candidates, by: { $0.session })
                .compactMap { $0.value.first }
            // Re-sort by matchScore to preserve ranking after deduplication
            return deduped.sorted { lhs, rhs in
                let left = lhs.matchScore ?? 0
                let right = rhs.matchScore ?? 0
                if left == right {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        case .animeKai:
            var bestByKey: [String: SoraAnimeMatch] = [:]
            for candidate in candidates {
                let normalized = candidate.normalizedTitle ?? normalizedTitle(candidate.title, provider: provider)
                let key = normalized.isEmpty ? candidate.session : normalized
                if let existing = bestByKey[key] {
                    let existingScore = existing.matchScore ?? -1
                    let candidateScore = candidate.matchScore ?? -1
                    if candidateScore > existingScore {
                        bestByKey[key] = candidate
                    }
                } else {
                    bestByKey[key] = candidate
                }
            }
            return bestByKey.values.sorted { lhs, rhs in
                let left = lhs.matchScore ?? 0
                let right = rhs.matchScore ?? 0
                if left == right {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return left > right
            }
        }
    }

    static func diceCoefficient(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        guard a.count > 1, b.count > 1 else { return 0.0 }
        let aBigrams = bigrams(from: a)
        let bBigrams = bigrams(from: b)
        var intersection = 0
        var bCounts = bBigrams
        for (gram, count) in aBigrams {
            if let bCount = bCounts[gram], bCount > 0 {
                let matches = min(count, bCount)
                intersection += matches
                bCounts[gram] = bCount - matches
            }
        }
        let total = aBigrams.values.reduce(0, +) + bBigrams.values.reduce(0, +)
        return total == 0 ? 0.0 : (2.0 * Double(intersection) / Double(total))
    }

    static func bigrams(from input: String) -> [String: Int] {
        let chars = Array(input)
        guard chars.count >= 2 else { return [:] }
        var out: [String: Int] = [:]
        for i in 0..<(chars.count - 1) {
            let gram = String([chars[i], chars[i + 1]])
            out[gram, default: 0] += 1
        }
        return out
    }

    static func romanToArabic(_ input: String) -> String {
        var out = input
        let map: [(String, String)] = [
            ("x", "10"),
            ("ix", "9"),
            ("viii", "8"),
            ("vii", "7"),
            ("vi", "6"),
            ("v", "5"),
            ("iv", "4"),
            ("iii", "3"),
            ("ii", "2"),
            ("i", "1")
        ]
        for (roman, arabic) in map {
            out = out.replacingOccurrences(
                of: "\\b\(roman)\\b",
                with: arabic,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    private static func extractMarkerNumber(from input: String, patterns: [String]) -> Int? {
        let normalized = romanToArabic(input)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            if let match = regex.firstMatch(in: normalized, options: [], range: range) {
                if match.numberOfRanges > 1 {
                    let numberRange = match.range(at: 1)
                    if let r = Range(numberRange, in: normalized) {
                        return Int(normalized[r])
                    }
                } else {
                    let chunk = String(normalized[Range(match.range, in: normalized)!])
                    let digits = chunk.filter { $0.isNumber }
                    return Int(digits)
                }
            }
        }
        return nil
    }

    private static func rankedCandidate(
        candidate: SoraAnimeMatch,
        normalizedTarget: String,
        normalizedTargetBase: String,
        wantedSeason: Int?,
        targetYear: Int?,
        targetFormat: String?,
        provider: StreamingProvider,
        normalizedQueries: [String]
    ) -> RankedCandidate {
        let normalizedCandidate = normalizedTitle(candidate.title, provider: provider)
        let baseScore = score(
            candidate: candidate,
            normalizedTarget: normalizedTarget,
            wantedSeason: wantedSeason,
            targetYear: targetYear,
            targetFormat: targetFormat,
            provider: provider
        )
        let queryScore = normalizedQueries.map { normalizedQuery in
            titleSimilarity(candidateTitle: candidate.title, normalizedTarget: normalizedQuery, provider: provider)
        }.max() ?? 0
        let combinedScore = min(max((baseScore * 0.78) + (queryScore * 0.22), 0), 1)
        let candidateBase = stripSequenceMarkers(from: normalizedCandidate, provider: provider)

        var contextParts: [String] = []
        if candidateBase == normalizedTargetBase || normalizedCandidate == normalizedTarget {
            contextParts.append("Closest title")
        } else if combinedScore >= 0.85 {
            contextParts.append("Strong title match")
        } else if combinedScore >= 0.7 {
            contextParts.append("Possible alt title")
        }
        if let episodeCount = candidate.episodeCount, episodeCount > 0 {
            let label = episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes"
            contextParts.append(label)
        }
        if let year = candidate.year {
            contextParts.append("\(year)")
        }

        let enriched = SoraAnimeMatch(
            id: candidate.id,
            title: candidate.title,
            imageURL: candidate.imageURL,
            session: candidate.session,
            detailURL: candidate.detailURL,
            year: candidate.year,
            format: candidate.format,
            episodeCount: candidate.episodeCount,
            normalizedTitle: normalizedCandidate,
            matchScore: combinedScore,
            matchContext: contextParts.isEmpty ? nil : contextParts.joined(separator: " | ")
        )
        return RankedCandidate(
            match: enriched,
            score: combinedScore,
            normalizedTitle: normalizedCandidate,
            context: enriched.matchContext
        )
    }

    private static func titleSimilarity(
        candidateTitle: String,
        normalizedTarget: String,
        provider: StreamingProvider
    ) -> Double {
        let normalizedCandidate = normalizedTitle(candidateTitle, provider: provider)
        let exactScore = diceCoefficient(normalizedCandidate, normalizedTarget)
        guard provider == .animeKai else {
            return exactScore
        }

        let candidateBase = stripSequenceMarkers(from: normalizedCandidate, provider: provider)
        let targetBase = stripSequenceMarkers(from: normalizedTarget, provider: provider)
        let baseScore = diceCoefficient(candidateBase, targetBase)
        return max(exactScore, (baseScore * 0.95) + (exactScore * 0.05))
    }

    private static func cleanAnimeKaiTitle(_ input: String) -> String {
        var out = romanToArabic(input)
        let season = extractSeasonMarkerNumber(from: out)
        let part = extractPartOnlyMarkerNumber(from: out)
        let cour = extractCourMarkerNumber(from: out)
        let hasFinalSeason = hasFinalSeasonMarker(out)

        out = out.lowercased()
        out = out.replacingOccurrences(of: #"(?i)\b\d+(st|nd|rd|th)\s*season\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\bseason\s*\d+\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\bs\s*\d+\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\bpart\s*\d+\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\bcour\s*\d+\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\b(?:the\s+)?final\s+season\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\b(tv|anime|subbed|dubbed|english dub|eng dub|uncensored|bd)\b"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        var suffixes: [String] = []
        if let season {
            suffixes.append("season \(season)")
        }
        if let part {
            suffixes.append("part \(part)")
        }
        if let cour {
            suffixes.append("cour \(cour)")
        }
        if hasFinalSeason {
            suffixes.append("final season")
        }

        if !suffixes.isEmpty {
            out = ([out] + suffixes).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSequenceMarkers(from normalizedTitle: String, provider: StreamingProvider) -> String {
        var out = normalizedTitle
        switch provider {
        case .animePahe:
            out = stripSeasonMarkers(out)
        case .animeKai:
            let patterns = [
                #"(?i)\bseason\s*\d+\b"#,
                #"(?i)\bpart\s*\d+\b"#,
                #"(?i)\bcour\s*\d+\b"#,
                #"(?i)\bfinal\s+season\b"#
            ]
            for pattern in patterns {
                out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            }
        }
        return out
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableUniqueQueries(_ queries: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = cleanTitle(trimmed)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    private static func coreAnimeKaiTokens(from normalizedTitle: String) -> Set<String> {
        let ignored: Set<String> = [
            "the", "a", "an", "of", "to", "no", "and", "or",
            "season", "part", "cour", "final", "movie", "special", "tv"
        ]
        let tokens = normalizedTitle
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count > 2 && !ignored.contains(token)
            }
        return Set(tokens)
    }
}

