import Foundation
import SwiftUI

final class MediaTracker: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var grouped: [MediaStatus: [MediaItem]] = [:]

    init(seed: [MediaItem] = []) {
        setItems(seed)
    }

    func setItems(_ items: [MediaItem]) {
        self.items = items
        rebuildGroups()
    }

    func updateStatus(for itemId: UUID, to status: MediaStatus) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].status = status
        rebuildGroups()
    }

    func upsert(_ item: MediaItem) {
        if let externalId = item.externalId,
           let index = items.firstIndex(where: { $0.externalId == externalId }) {
            items[index] = item
        } else if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        rebuildGroups()
    }

    func items(for status: MediaStatus) -> [MediaItem] {
        grouped[status, default: []]
    }

    func count(for status: MediaStatus) -> Int {
        grouped[status, default: []].count
    }

    private func rebuildGroups() {
        grouped = Dictionary(grouping: items, by: { $0.status })
    }
}
