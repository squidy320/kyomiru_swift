import SwiftUI
import Observation

@Observable
final class ListManagerViewModel {
    var status: MediaStatus
    var currentEpisode: Int
    var rating: Int
    let totalEpisodes: Int?
    let title: String

    init(item: MediaItem) {
        self.status = item.status
        self.currentEpisode = item.currentEpisode
        self.rating = item.userRating
        self.totalEpisodes = item.totalEpisodes
        self.title = item.title
    }

    func apply(to item: MediaItem) -> MediaItem {
        var updated = item
        updated.status = status
        updated.currentEpisode = max(currentEpisode, 0)
        updated.userRating = min(max(rating, 0), 100)
        return updated
    }
}

struct ListManagerView: View {
    let item: MediaItem
    @Bindable var viewModel: ListManagerViewModel
    let onSave: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Status")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Picker("Status", selection: $viewModel.status) {
                        ForEach(MediaStatus.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Episodes Watched")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Stepper(
                        value: $viewModel.currentEpisode,
                        in: 0...(viewModel.totalEpisodes ?? 999),
                        step: 1
                    ) {
                        Text("Episode \(viewModel.currentEpisode)")
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Rating")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Slider(value: Binding(
                        get: { Double(viewModel.rating) },
                        set: { viewModel.rating = Int($0) }
                    ), in: 0...100, step: 1)
                    Text("\(viewModel.rating)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()
            }
            .padding(16)
            .background(Theme.baseBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(viewModel.apply(to: item))
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }
}
