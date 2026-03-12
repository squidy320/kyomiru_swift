import Foundation

enum MPVSupport {
    static let isAvailable: Bool = {
#if canImport(Libmpv)
        return true
#else
        return false
#endif
    }()
}
