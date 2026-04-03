import SwiftUI
import UIKit

enum PlatformSupport {
    static var prefersTabletLayout: Bool {
#if targetEnvironment(macCatalyst)
        return true
#else
        return UIDevice.current.userInterfaceIdiom == .pad
#endif
    }

    static var supportsPointerHover: Bool {
#if targetEnvironment(macCatalyst)
        return true
#else
        return false
#endif
    }
}

private struct HoverLiftModifier: ViewModifier {
    @State private var isHovered = false
    let enabled: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && isHovered ? 1.015 : 1.0)
            .brightness(enabled && isHovered ? 0.03 : 0)
            .shadow(
                color: enabled && isHovered ? .black.opacity(0.22) : .clear,
                radius: enabled && isHovered ? 14 : 0,
                x: 0,
                y: enabled && isHovered ? 8 : 0
            )
            .onHover { hovering in
                guard enabled else { return }
                if reduceMotion {
                    isHovered = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isHovered = hovering
                    }
                }
            }
    }
}

extension View {
    func platformHoverLift(reduceMotion: Bool = false) -> some View {
        modifier(HoverLiftModifier(enabled: PlatformSupport.supportsPointerHover, reduceMotion: reduceMotion))
    }
}
