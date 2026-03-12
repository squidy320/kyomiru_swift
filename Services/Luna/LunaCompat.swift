import Foundation

// Minimal compatibility layer for Luna JSLoader integration.

final class LunaLogger {
    static let shared = LunaLogger()

    func log(_ message: String, type: String = "Debug") {
        switch type.lowercased() {
        case "error":
            AppLog.error(.network, "[Luna] \(message)")
        case "warning":
            AppLog.debug(.network, "[Luna][Warning] \(message)")
        default:
            AppLog.debug(.network, "[Luna] \(message)")
        }
    }
}

struct ServiceMetadata: Codable, Hashable {
    let sourceName: String
    let author: Author
    let iconUrl: String
    let version: String
    let language: String
    let baseUrl: String
    let streamType: String
    let quality: String
    let searchBaseUrl: String
    let scriptUrl: String
    let softsub: Bool?
    let multiStream: Bool?
    let multiSubs: Bool?
    let type: String?
    let novel: Bool?
    let settings: Bool?

    struct Author: Codable, Hashable {
        let name: String
        let icon: String
    }
}

struct Service: Identifiable, Hashable {
    let id: UUID
    let metadata: ServiceMetadata
    let jsScript: String
    let url: String
    let isActive: Bool
    let sortIndex: Int64
}

final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension URLSession {
    static var custom: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    static func fetchData(allowRedirects: Bool) -> URLSession {
        if allowRedirects {
            return URLSession(configuration: .default)
        }
        return URLSession(configuration: .default, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    static var randomUserAgent: String {
        let agents = [
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 15_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.7 Mobile/15E148 Safari/604.1"
        ]
        return agents.randomElement() ?? agents[0]
    }
}
