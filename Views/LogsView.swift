import SwiftUI

struct LogsView: View {
    @StateObject private var store = LogStore.shared
    @State private var showShare = false
    @State private var exportURL: URL?

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            List {
                ForEach(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(entry.level) - \(entry.category.rawValue)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Text(entry.message)
                            .foregroundColor(.white)
                            .font(.system(size: 13))
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .listRowBackground(Color.black)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Share .txt") {
                    exportURL = store.exportURL()
                    showShare = true
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") {
                    store.clear()
                }
                .foregroundColor(.red)
            }
        }
        .sheet(isPresented: $showShare) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
