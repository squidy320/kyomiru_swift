import SwiftUI

final class SettingsState: ObservableObject {
    @Published var defaultAudio: String = "Sub"
    @Published var defaultQuality: String = "Auto"
    @Published var autoSyncAniList: Bool = true
    @Published var showPlayerDebugOverlay: Bool = false
}
