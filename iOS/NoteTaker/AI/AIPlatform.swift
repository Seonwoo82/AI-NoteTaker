import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    static var appWindowBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(.systemBackground)
#endif
    }

    static var appSeparator: Color {
#if os(macOS)
        Color(nsColor: .separatorColor)
#else
        Color(.separator)
#endif
    }
}
