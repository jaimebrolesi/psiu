import AppKit
import SwiftUI

// MARK: - Notch window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Host: NSHostingView<PillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Geometry and open state of a panel (one per screen).
@MainActor
final class PanelGeometry: ObservableObject {
    @Published var isOpen = false
    @Published var w: CGFloat = 230   // closed: notch width + ears
    @Published var h: CGFloat = 32    // closed: menu bar height
    @Published var W: CGFloat = 330   // open
    @Published var H: CGFloat = 260
    var screenFrame: NSRect = .zero

    /// Closed: extra width on each side while a dot is lit, so the dot clears the physical notch.
    @Published var dotsRoom: CGFloat = 0
    var hasNotch = false
    /// Closed width, with room for the dots when needed.
    var closedWidth: CGFloat { w + 2 * dotsRoom }
    /// A dot (5) and its gap to the robot (6), plus 3 so it doesn't touch the notch's edge.
    static let dotsRoomWidth: CGFloat = 14

    /// Open, the top strip grows to this height so Psiu can be bigger.
    static let openStripHeight: CGFloat = 44
    /// Height of the top strip, closed or open.
    var stripHeight: CGFloat { isOpen ? max(h, Self.openStripHeight) : h }
}
