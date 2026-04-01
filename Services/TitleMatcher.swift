import Foundation

enum TitleMatcher {
    static func bestMatch(
        target: AniListMedia,
        candidates: [SoraAnimeMatch]
    ) -> SoraAnimeMatch? {
        AppLog.debug(.matching, "best match start mediaId=\(target.id) candidates=\(candidates.count)")
        let targetTitle = target.title.best
        let wantedSeason = extractSeasonNumber(from: targetTitle)
        let normalizedTarget = cleanTitle(stripSeasonMarkers(targetTitle))
        let targetYear = target.seasonYear
        let targetFormat = target.format ?? target.status

        let best = candidates.max { a, b in
            score(candidate: a, normalizedTarget: normalizedTarget, wantedSeason: wantedSeason,
                  targetYear: targetYear, targetFormat: targetFormat)
            < score(candidate: b, normalizedTarget: normalizedTarget, wantedSeason: wantedSeason,
                    targetYear: targetYear, targetFormat: targetFormat)
        }
        AppLog.debug(.matching, "best match result mediaId=\(target.id) matched=\(best != nil)")
        return best
    }

    static func score(
        candidate: SoraAnimeMatch,
        normalizedTarget: String,
        wantedSeason: Int?,
        targetYear: Int?,
        targetFormat: String?
    ) -> Double {
        let titleScore = diceCoefficient(cleanTitle(candidate.title), normalizedTarget)
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
        if let wantedSeason {
            if candidateSeason == wantedSeason {
                score += 0.15 // Increased bonus for exact season match
            } else if let cs = candidateSeason, cs != wantedSeason {
                score -= 0.30 // Heavier penalty for wrong season
            } else if wantedSeason == 1 {
                score += 0.08
            } else {
                score -= 0.10
            }
        }
        
        // Bonus for "Part" or "Cour" match if target title has it
        if normalizedTarget.contains("part") || normalizedTarget.contains("cour") {
            let cTitle = candidate.title.lowercased()
            if (normalizedTarget.contains("part") && cTitle.contains("part")) ||
               (normalizedTarget.contains("cour") && cTitle.contains("cour")) {
                score += 0.05
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
}

