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
    var hovering = false
    var w: CGFloat = 230   // closed: notch width + ears
    /// Closed, the black on each side of the camera: room for the usage and for Psiu.
    static let ear: CGFloat = 34
    var h: CGFloat = 32    // closed: menu bar height
    var W: CGFloat = 680   // open
    var H: CGFloat = 260
    @ObservationIgnored var screenFrame: NSRect = .zero

    /// Open, the top strip grows to this height so Psiu can be bigger.
    static let openStripHeight: CGFloat = 44
    /// Height of the top strip, closed or open.
    var stripHeight: CGFloat { isOpen ? max(h, Self.openStripHeight) : shapeSize(open: false, swollen: swollen).height }

    /// Hovered while closed, the notch swells a little.
    var swollen: Bool { hovering && !isOpen }
    static let hoverGrowth = CGSize(width: 8, height: 4)
    /// The top corners flare out into the screen's edge; the bottom ones are rounded.
    static let closedFlare: CGFloat = 8, openFlare: CGFloat = 14
    var flare: CGFloat { isOpen ? Self.openFlare : Self.closedFlare }
    var radius: CGFloat { isOpen ? 24 : 10 }
    /// Room around the shape while it moves, so neither a spring's overshoot nor the shadow is cut by the window's edge.
    static let room: CGFloat = 16

    /// The black shape, flares included: the ears and the panel keep their width between the flares.
    func shapeSize(open: Bool, swollen: Bool) -> CGSize {
        if open { return CGSize(width: W + 2 * Self.openFlare, height: H) }
        let grow = swollen ? Self.hoverGrowth : .zero
        return CGSize(width: w + 2 * Self.closedFlare + 2 * grow.width, height: h + grow.height)
    }
    var shapeSize: CGSize { shapeSize(open: isOpen, swollen: swollen) }

    /// The window: closed and still, exactly the notch, so the menu bar stays free around it.
    func windowSize(open: Bool, swollen: Bool) -> CGSize {
        let s = shapeSize(open: open, swollen: swollen)
        let room = open || swollen ? Self.room : 0
        return CGSize(width: s.width + 2 * room, height: s.height + room)
    }
}
