import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct EpisodeImportPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = [
            "mov",
            "mp4",
            "m4v",
            "ts",
            "m3u8"
        ].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct EpisodeImportReviewSheet: View {
    @Binding var candidates: [EpisodeImportCandidate]
    let onConfirm: ([EpisodeImportCandidate]) -> Void
    let onCancel: () -> Void

    private var canImport: Bool {
        candidates.allSatisfy { $0.episodeNumber != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($candidates) { $candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.fileName)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(candidate.url.lastPathComponent)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        TextField("Ep", value: $candidate.episodeNumber, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            }
            .navigationTitle("Review Episodes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onConfirm(candidates) }
                        .disabled(!canImport)
                }
            }
        }
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        return formatter
    }
}
