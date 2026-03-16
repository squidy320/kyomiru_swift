import Foundation

enum TitleSanitizer {
    private static let patterns: [String] = [
        #"(?i)\s*:\s*"#,
        #"(?i)\s*-\s*"#,
        #"(?i)\b(2nd|second|3rd|third|4th|fourth)\s+season\b"#,
        #"(?i)\bseason\s+\d+\b"#,
        #"(?i)\bpart\s+\d+\b"#,
        #"(?i)\bcour\s+\d+\b"#,
        #"(?i)\bfinal\s+season\b"#,
        #"(?i)\bthe\s+final\s+season\b"#,
        #"(?i)\b(OVA|OAD|SPECIALS?)\b"#
    ]

    static func sanitize(_ title: String) -> String {
        var result = title
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression]
            )
        }
        result = result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
