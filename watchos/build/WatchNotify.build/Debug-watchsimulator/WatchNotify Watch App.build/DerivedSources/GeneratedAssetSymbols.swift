import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "icon_call" asset catalog image resource.
    static let iconCall = DeveloperToolsSupport.ImageResource(name: "icon_call", bundle: resourceBundle)

    /// The "icon_def" asset catalog image resource.
    static let iconDef = DeveloperToolsSupport.ImageResource(name: "icon_def", bundle: resourceBundle)

    /// The "icon_dg" asset catalog image resource.
    static let iconDg = DeveloperToolsSupport.ImageResource(name: "icon_dg", bundle: resourceBundle)

    /// The "icon_ggcard" asset catalog image resource.
    static let iconGgcard = DeveloperToolsSupport.ImageResource(name: "icon_ggcard", bundle: resourceBundle)

    /// The "icon_hana" asset catalog image resource.
    static let iconHana = DeveloperToolsSupport.ImageResource(name: "icon_hana", bundle: resourceBundle)

    /// The "icon_kakao" asset catalog image resource.
    static let iconKakao = DeveloperToolsSupport.ImageResource(name: "icon_kakao", bundle: resourceBundle)

    /// The "icon_kb" asset catalog image resource.
    static let iconKb = DeveloperToolsSupport.ImageResource(name: "icon_kb", bundle: resourceBundle)

    /// The "icon_kona" asset catalog image resource.
    static let iconKona = DeveloperToolsSupport.ImageResource(name: "icon_kona", bundle: resourceBundle)

    /// The "icon_message" asset catalog image resource.
    static let iconMessage = DeveloperToolsSupport.ImageResource(name: "icon_message", bundle: resourceBundle)

    /// The "icon_naver" asset catalog image resource.
    static let iconNaver = DeveloperToolsSupport.ImageResource(name: "icon_naver", bundle: resourceBundle)

    /// The "icon_sh" asset catalog image resource.
    static let iconSh = DeveloperToolsSupport.ImageResource(name: "icon_sh", bundle: resourceBundle)

    /// The "icon_teams" asset catalog image resource.
    static let iconTeams = DeveloperToolsSupport.ImageResource(name: "icon_teams", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "icon_call" asset catalog image.
    static var iconCall: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconCall)
#else
        .init()
#endif
    }

    /// The "icon_def" asset catalog image.
    static var iconDef: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconDef)
#else
        .init()
#endif
    }

    /// The "icon_dg" asset catalog image.
    static var iconDg: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconDg)
#else
        .init()
#endif
    }

    /// The "icon_ggcard" asset catalog image.
    static var iconGgcard: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconGgcard)
#else
        .init()
#endif
    }

    /// The "icon_hana" asset catalog image.
    static var iconHana: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconHana)
#else
        .init()
#endif
    }

    /// The "icon_kakao" asset catalog image.
    static var iconKakao: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconKakao)
#else
        .init()
#endif
    }

    /// The "icon_kb" asset catalog image.
    static var iconKb: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconKb)
#else
        .init()
#endif
    }

    /// The "icon_kona" asset catalog image.
    static var iconKona: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconKona)
#else
        .init()
#endif
    }

    /// The "icon_message" asset catalog image.
    static var iconMessage: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconMessage)
#else
        .init()
#endif
    }

    /// The "icon_naver" asset catalog image.
    static var iconNaver: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconNaver)
#else
        .init()
#endif
    }

    /// The "icon_sh" asset catalog image.
    static var iconSh: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconSh)
#else
        .init()
#endif
    }

    /// The "icon_teams" asset catalog image.
    static var iconTeams: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .iconTeams)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "icon_call" asset catalog image.
    static var iconCall: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconCall)
#else
        .init()
#endif
    }

    /// The "icon_def" asset catalog image.
    static var iconDef: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconDef)
#else
        .init()
#endif
    }

    /// The "icon_dg" asset catalog image.
    static var iconDg: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconDg)
#else
        .init()
#endif
    }

    /// The "icon_ggcard" asset catalog image.
    static var iconGgcard: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconGgcard)
#else
        .init()
#endif
    }

    /// The "icon_hana" asset catalog image.
    static var iconHana: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconHana)
#else
        .init()
#endif
    }

    /// The "icon_kakao" asset catalog image.
    static var iconKakao: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconKakao)
#else
        .init()
#endif
    }

    /// The "icon_kb" asset catalog image.
    static var iconKb: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconKb)
#else
        .init()
#endif
    }

    /// The "icon_kona" asset catalog image.
    static var iconKona: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconKona)
#else
        .init()
#endif
    }

    /// The "icon_message" asset catalog image.
    static var iconMessage: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconMessage)
#else
        .init()
#endif
    }

    /// The "icon_naver" asset catalog image.
    static var iconNaver: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconNaver)
#else
        .init()
#endif
    }

    /// The "icon_sh" asset catalog image.
    static var iconSh: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconSh)
#else
        .init()
#endif
    }

    /// The "icon_teams" asset catalog image.
    static var iconTeams: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .iconTeams)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

