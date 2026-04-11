import SwiftUI

public struct UIConstants {
    private static var windowBounds: CGRect {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return UIScreen.main.bounds
        }
        return window.bounds
    }

    static let cardWidth: CGFloat = 120
    static let cardHeight: CGFloat = 180
    static let episodeCardHeight: CGFloat = 110
    static let standardPadding: CGFloat = 16
    static let interCardSpacing: CGFloat = 12
    static let bottomBarHeight: CGFloat = 72
    static var heroHeight: CGFloat {
        let width = windowBounds.width
        if PlatformSupport.prefersTabletLayout { return 420 }
        if width <= 375 { return 360 }
        if width <= 414 { return 390 }
        return 420
    }
    static var heroHeightCompact: CGFloat {
        let width = windowBounds.width
        if PlatformSupport.prefersTabletLayout { return 320 }
        if width <= 375 { return 250 }
        if width <= 414 { return 270 }
        return 290
    }
    static var libraryProfileHeroHeight: CGFloat {
        let width = windowBounds.width
        if PlatformSupport.prefersTabletLayout { return 260 }
        if width <= 375 { return 170 }
        if width <= 414 { return 188 }
        return 204
    }
    static var libraryProfileAvatarSize: CGFloat {
        PlatformSupport.prefersTabletLayout ? 112 : 94
    }
    static var libraryProfileAvatarOverlap: CGFloat {
        PlatformSupport.prefersTabletLayout ? 54 : 46
    }
    static let smallPadding: CGFloat = 8
    static let tinyPadding: CGFloat = 6
    static let microPadding: CGFloat = 4
    static let heroTopPadding: CGFloat = 2
    static var posterCardWidth: CGFloat {
        let width = windowBounds.width
        if PlatformSupport.prefersTabletLayout { return 200 }
        if width <= 375 { return 140 }
        if width <= 414 { return 150 }
        return 160
    }
    static var posterCardHeight: CGFloat {
        posterCardWidth * 1.47
    }
    static var continueCardWidth: CGFloat {
        let width = windowBounds.width
        if PlatformSupport.prefersTabletLayout { return 340 }
        return max(240, min(300, width * 0.7))
    }
    static var continueCardHeight: CGFloat {
        continueCardWidth * 0.54
    }
    static var episodeThumbWidth: CGFloat {
        let width = windowBounds.width
        if PlatformSupport.prefersTabletLayout { return 180 }
        if width <= 375 { return 120 }
        return 140
    }
    static var episodeThumbHeight: CGFloat {
        episodeThumbWidth * 0.57
    }
    static let avatarSize: CGFloat = 38
    static let avatarFallbackSize: CGFloat = 42
    static let cornerRadiusSmall: CGFloat = 14
    static let cornerRadiusLarge: CGFloat = 16
    static let toolbarIconSize: CGFloat = 36
    static let circleButtonSize: CGFloat = 40
    static let buttonHorizontalPadding: CGFloat = 16
    static let buttonVerticalPadding: CGFloat = 10
    static let chipVerticalPadding: CGFloat = 4
    static let overlayPadding: CGFloat = 14
    static let rowPadding: CGFloat = 12
    static let ratingBadgePadding: CGFloat = 6
    static let cardCornerRadius: CGFloat = 18
    static let sourceRowImageWidth: CGFloat = 42
    static let sourceRowImageHeight: CGFloat = 56
    static let smallCornerRadius: CGFloat = 8
    static let mediumPadding: CGFloat = 10
}
