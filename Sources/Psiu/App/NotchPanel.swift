import AppKit
import Observation
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
@Observable @MainActor
final class PanelGeometry {
    var isOpen = false
    var w: CGFloat = 230   // closed: notch width + ears
    var h: CGFloat = 32    // closed: menu bar height
    var W: CGFloat = 330   // open
    var H: CGFloat = 260
    @ObservationIgnored var screenFrame: NSRect = .zero

    /// Open, the top strip grows to this height so Psiu can be bigger.
    static let openStripHeight: CGFloat = 44
    /// Height of the top strip, closed or open.
    var stripHeight: CGFloat { isOpen ? max(h, Self.openStripHeight) : h }
}
