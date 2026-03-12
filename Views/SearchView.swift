import SwiftUI

struct SearchView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search")
                .font(.title2.bold())
                .foregroundColor(Theme.textPrimary)

            Text("Search across your library and discovery feed.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.baseBackground)
    }
}
