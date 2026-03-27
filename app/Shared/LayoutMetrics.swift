import SwiftUI

enum LayoutMetrics {
    #if os(tvOS)
    static let gridMinWidth: CGFloat = 300
    static let gridMaxWidth: CGFloat = 450
    static let panelWidth: CGFloat = 400
    #else
    static let gridMinWidth: CGFloat = 200
    static let gridMaxWidth: CGFloat = 300
    static let panelWidth: CGFloat = 280
    #endif
}
