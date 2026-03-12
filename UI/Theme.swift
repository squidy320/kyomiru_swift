import SwiftUI

enum Theme {
    static let baseBackground = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let surface = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let accent = Color(red: 0.47, green: 0.72, blue: 1.0)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.63, green: 0.66, blue: 0.74)

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.09, blue: 0.12),
            Color(red: 0.03, green: 0.03, blue: 0.05)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
