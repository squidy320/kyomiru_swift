import SwiftUI

struct RatingBadge: View {
    let score: Int?

    var body: some View {
        let text = score == nil ? "NR" : "\(score ?? 0)"
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundColor(.white)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
    }
}
