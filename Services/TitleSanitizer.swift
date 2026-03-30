import Foundation

enum TitleSanitizer {
    static func sanitize(_ title: String) -> String {
        var result = title

        let suffixPatterns = [
            #"\s+\((?i:tv)\)\s*$"#,
            #"\s+\(\d{4}\)\s*$"#,
            #"\s+(?i:season|part|cour)\s+(?:\d+|[ivx]+)\s*$"#,
            #"\s+(?i:\d+(?:st|nd|rd|th)\s+season)\s*$"#
        ]
        for pattern in suffixPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression]
            )
        }

        result = result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
