import Foundation
import Network

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnWiFi: Bool = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "kyomiru.network.monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                self?.isOnWiFi = wifi
            }
        }
        monitor.start(queue: queue)
    }
}
