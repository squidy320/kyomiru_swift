import Foundation

enum TitleSanitizer {
    private static let patterns: [String] = [
        #"(?i)\s+((Season|Part|Cour|2nd|3rd|4th|Final|The Final)\s+(\d+|I+)|[:\-].*|\(TV\)|\(\d{4}\))"#
    ]

    static func sanitize(_ title: String) -> String {
        var result = title
        for pattern in patterns {
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
