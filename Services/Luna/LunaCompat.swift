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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)

        sourceName = (try? container.decodeIfPresent(String.self, forKey: .sourceName))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .sourceName))
            ?? "Unknown"
        author = (try? container.decode(Author.self, forKey: .author))
            ?? (try? legacy.decode(Author.self, forKey: .author))
            ?? Author(name: "Unknown", icon: "")
        iconUrl = (try? container.decodeIfPresent(String.self, forKey: .iconUrl))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .iconUrl))
            ?? ""
        version = (try? container.decodeIfPresent(String.self, forKey: .version))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .version))
            ?? ""
        language = (try? container.decodeIfPresent(String.self, forKey: .language))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .language))
            ?? "en"
        baseUrl = (try? container.decodeIfPresent(String.self, forKey: .baseUrl))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .baseUrl))
            ?? ""
        streamType = (try? container.decodeIfPresent(String.self, forKey: .streamType))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .streamType))
            ?? ""
        quality = (try? container.decodeIfPresent(String.self, forKey: .quality))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .quality))
            ?? ""
        searchBaseUrl = (try? container.decodeIfPresent(String.self, forKey: .searchBaseUrl))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .searchBaseUrl))
            ?? ""
        scriptUrl = (try? container.decodeIfPresent(String.self, forKey: .scriptUrl))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .scriptUrl))
            ?? ""
        softsub = (try? container.decodeIfPresent(Bool.self, forKey: .softsub))
            ?? (try? legacy.decodeIfPresent(Bool.self, forKey: .softsub))
        multiStream = (try? container.decodeIfPresent(Bool.self, forKey: .multiStream))
            ?? (try? legacy.decodeIfPresent(Bool.self, forKey: .multiStream))
        multiSubs = (try? container.decodeIfPresent(Bool.self, forKey: .multiSubs))
            ?? (try? legacy.decodeIfPresent(Bool.self, forKey: .multiSubs))
        type = (try? container.decodeIfPresent(String.self, forKey: .type))
            ?? (try? legacy.decodeIfPresent(String.self, forKey: .type))
        novel = (try? container.decodeIfPresent(Bool.self, forKey: .novel))
            ?? (try? legacy.decodeIfPresent(Bool.self, forKey: .novel))
        settings = (try? container.decodeIfPresent(Bool.self, forKey: .settings))
            ?? (try? legacy.decodeIfPresent(Bool.self, forKey: .settings))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(author, forKey: .author)
        try container.encode(iconUrl, forKey: .iconUrl)
        try container.encode(version, forKey: .version)
        try container.encode(language, forKey: .language)
        try container.encode(baseUrl, forKey: .baseUrl)
        try container.encode(streamType, forKey: .streamType)
        try container.encode(quality, forKey: .quality)
        try container.encode(searchBaseUrl, forKey: .searchBaseUrl)
        try container.encode(scriptUrl, forKey: .scriptUrl)
        try container.encodeIfPresent(softsub, forKey: .softsub)
        try container.encodeIfPresent(multiStream, forKey: .multiStream)
        try container.encodeIfPresent(multiSubs, forKey: .multiSubs)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(novel, forKey: .novel)
        try container.encodeIfPresent(settings, forKey: .settings)
    }

    enum CodingKeys: String, CodingKey {
        case sourceName
        case author
        case iconUrl
        case version
        case language
        case baseUrl
        case streamType
        case quality
        case searchBaseUrl
        case scriptUrl
        case softsub
        case multiStream
        case multiSubs
        case type
        case novel
        case settings
    }

    enum LegacyKeys: String, CodingKey {
        case sourceName = "source_name"
        case author
        case iconUrl = "icon_url"
        case version
        case language
        case baseUrl = "base_url"
        case streamType = "stream_type"
        case quality
        case searchBaseUrl = "search_base_url"
        case scriptUrl = "script_url"
        case softsub
        case multiStream = "multi_stream"
        case multiSubs = "multi_subs"
        case type
        case novel
        case settings
    }

    struct Author: Codable, Hashable {
        let name: String
        let icon: String

        init(name: String, icon: String) {
            self.name = name
            self.icon = icon
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            name = (try? container.decodeIfPresent(String.self, forKey: .name))
                ?? (try? legacy.decodeIfPresent(String.self, forKey: .name))
                ?? "Unknown"
            icon = (try? container.decodeIfPresent(String.self, forKey: .icon))
                ?? (try? legacy.decodeIfPresent(String.self, forKey: .icon))
                ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(icon, forKey: .icon)
        }

        enum CodingKeys: String, CodingKey {
            case name
            case icon
        }

        enum LegacyKeys: String, CodingKey {
            case name
            case icon = "icon_url"
        }
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
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    static func fetchData(allowRedirects: Bool) -> URLSession {
        if allowRedirects {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = true
            return URLSession(configuration: config)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
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
