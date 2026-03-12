import Foundation

enum MPVSupport {
    static let isAvailable: Bool = {
#if canImport(mpv)
        return true
#else
        return false
#endif
    }()
}
