import Foundation

enum NetworkRetry {
    static func withRetries<T>(
        label: String,
        attempts: Int = 3,
        baseDelay: TimeInterval = 0.8,
        task: @escaping () async throws -> T
    ) async throws -> T {
        precondition(attempts >= 1)
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await task()
            } catch {
                lastError = error
                if attempt >= attempts || !shouldRetry(error) {
                    throw error
                }
                let delay = baseDelay * pow(2.0, Double(attempt - 1))
                AppLog.debug(.network, "retry \(label) attempt=\(attempt + 1)/\(attempts) delay=\(String(format: "%.2f", delay)) error=\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .badServerResponse,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .resourceUnavailable,
                 .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
