import SwiftUI
import UIKit

struct LogsView: View {
    @StateObject private var store = LogStore.shared
    @State private var sharePayload: SharePayload?

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
                    sharePayload = SharePayload(items: [store.exportURL()])
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") {
                    store.clear()
                }
                .foregroundColor(.red)
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            popover.sourceRect = popover.sourceView?.bounds ?? .zero
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
