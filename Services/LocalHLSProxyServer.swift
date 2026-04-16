#if os(iOS)
import Foundation
import Network

final class LocalHLSProxyServer {
    static let shared = LocalHLSProxyServer()

    private let port: NWEndpoint.Port = 8765
    private let queue = DispatchQueue(label: "com.kyomiru.local-hls-proxy", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    AppLog.debug(.player, "local hls proxy ready port=\(self.port.rawValue)")
                case .failed(let error):
                    AppLog.error(.player, "local hls proxy failed \(error.localizedDescription)")
                    self.isRunning = false
                    self.listener = nil
                case .cancelled:
                    self.isRunning = false
                    self.listener = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            AppLog.error(.player, "local hls proxy start failed \(error.localizedDescription)")
        }
    }

    func proxyURL(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL else { return fileURL }
        start()

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port.rawValue)
        components.path = "/proxy"
        components.queryItems = [
            URLQueryItem(name: "url", value: fileURL.absoluteString)
        ]
        return components.url
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = request.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                self.sendEmptyResponse(connection, statusLine: "400 Bad Request")
                return
            }

            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                self.sendEmptyResponse(connection, statusLine: "400 Bad Request")
                return
            }

            let method = parts[0]
            let path = parts[1]
            guard let components = URLComponents(string: "http://localhost" + path),
                  let urlValue = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let targetURL = URL(string: urlValue),
                  targetURL.isFileURL else {
                self.sendEmptyResponse(connection, statusLine: "400 Bad Request")
                return
            }

            let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") })
                .flatMap { $0.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) }

            Task {
                await self.serveLocalFile(targetURL, on: connection, range: rangeHeader, isHead: method == "HEAD")
                self.receiveRequest(on: connection)
            }
        }
    }

    private func serveLocalFile(_ url: URL, on connection: NWConnection, range: String?, isHead: Bool) async {
        if url.pathExtension.lowercased() == "m3u8",
           let data = try? Data(contentsOf: url),
           let manifest = String(data: data, encoding: .utf8) {
            let rewritten = rewriteManifest(manifest, manifestURL: url)
            let body = rewritten.data(using: .utf8) ?? data
            sendData(body, contentType: "application/x-mpegURL", on: connection, isHead: isHead)
            return
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            sendEmptyResponse(connection, statusLine: "404 Not Found")
            return
        }

        let totalSize = fileSize.int64Value
        var start: Int64 = 0
        var end: Int64 = max(totalSize - 1, 0)
        var isPartial = false

        if let range, let parsedRange = parseRange(range, fileSize: totalSize) {
            start = parsedRange.lowerBound
            end = parsedRange.upperBound
            isPartial = true
        }

        let length = max(end - start + 1, 0)
        let contentType = mimeType(for: url.pathExtension)
        var header = "HTTP/1.1 \(isPartial ? "206 Partial Content" : "200 OK")\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        if isPartial {
            header += "Content-Range: bytes \(start)-\(end)/\(totalSize)\r\n"
        }
        header += "\r\n"

        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, !isHead else { return }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            try? handle.seek(toOffset: UInt64(start))
            self?.stream(handle: handle, remaining: length, on: connection)
        })
    }

    private func rewriteManifest(_ manifest: String, manifestURL: URL) -> String {
        let baseFolder = manifestURL.deletingLastPathComponent()

        return manifest
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return line }

                if trimmed.hasPrefix("#EXT-X-KEY:") || trimmed.hasPrefix("#EXT-X-MAP:") {
                    return rewriteQuotedURI(in: line, relativeTo: baseFolder)
                }

                guard !trimmed.hasPrefix("#"),
                      let localURL = URL(string: trimmed, relativeTo: baseFolder)?.absoluteURL,
                      let proxyURL = proxyURL(for: localURL) else {
                    return line
                }

                return proxyURL.absoluteString
            }
            .joined(separator: "\n")
    }

    private func rewriteQuotedURI(in line: String, relativeTo baseFolder: URL) -> String {
        guard let uriRange = line.range(of: #"URI="[^"]*""#, options: .regularExpression) else {
            return line
        }

        let matched = String(line[uriRange])
        let rawValue = matched
            .replacingOccurrences(of: #"URI=""#, with: "")
            .replacingOccurrences(of: "\"", with: "")

        guard let localURL = URL(string: rawValue, relativeTo: baseFolder)?.absoluteURL,
              let proxyURL = proxyURL(for: localURL) else {
            return line
        }

        return line.replacingCharacters(in: uriRange, with: #"URI="\#(proxyURL.absoluteString)""#)
    }

    private func parseRange(_ header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let value = header.replacingOccurrences(of: "bytes=", with: "")
        let parts = value.components(separatedBy: "-")
        guard let start = Int64(parts[0]) else { return nil }
        let end = parts.count > 1 && !parts[1].isEmpty ? (Int64(parts[1]) ?? (fileSize - 1)) : (fileSize - 1)
        guard start >= 0, end >= start else { return nil }
        return start...min(end, fileSize - 1)
    }

    private func stream(handle: FileHandle, remaining: Int64, on connection: NWConnection) {
        var remaining = remaining
        let chunkSize = Int64(128 * 1024)

        func sendNext() {
            guard remaining > 0 else {
                try? handle.close()
                return
            }

            let length = Int(min(remaining, chunkSize))
            guard let data = try? handle.read(upToCount: length), !data.isEmpty else {
                try? handle.close()
                return
            }

            remaining -= Int64(data.count)
            connection.send(content: data, isComplete: false, completion: .contentProcessed { error in
                if error == nil {
                    sendNext()
                } else {
                    try? handle.close()
                }
            })
        }

        sendNext()
    }

    private func sendData(_ data: Data, contentType: String, on connection: NWConnection, isHead: Bool) {
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(data.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n\r\n"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            guard !isHead else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        })
    }

    private func sendEmptyResponse(_ connection: NWConnection, statusLine: String) {
        let response = "HTTP/1.1 \(statusLine)\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8":
            return "application/x-mpegURL"
        case "ts", "m2ts", "mts":
            return "video/mp2t"
        case "m4s":
            return "video/iso.segment"
        case "mp4":
            return "video/mp4"
        case "key":
            return "application/octet-stream"
        default:
            return "application/octet-stream"
        }
    }
}
#endif
