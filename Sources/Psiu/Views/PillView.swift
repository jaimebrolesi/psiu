import AppKit
import PsiuCore
import SwiftUI

struct PillView: View {
    let store: Store
    let app: AppDelegate
    let displayID: CGDirectDisplayID
    let geo: PanelGeometry

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(flare: geo.flare, radius: geo.radius).fill(Color.black)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        usage
                        Spacer(minLength: 0)
                        // Peeking, the robot rests on the bottom of the strip: the clipping edge matches the notch's edge.
                        let peeking = store.color == .backgroundBlue && !geo.isOpen
                        RobotView(color: store.color, tired: store.heavyContext, peeking: peeking,
                                  bandaged: store.bandaged, revivingUntil: store.revivingUntil, relief: store.relief,
                                  paused: store.displayAsleep, badge: store.greenDot)
                            .aspectRatio(60.0 / 46.0, contentMode: .fit)
                            .frame(width: geo.isOpen ? 42 : 26, height: geo.isOpen ? 32 : 20)
                            .scaleEffect(geo.swollen ? hoverScale : 1)
                            .frame(maxHeight: .infinity, alignment: peeking ? .bottom : .center)
                    }
                    .padding(.leading, geo.isOpen ? 10 : 7.5)   // closed: the percentage as far from the edge as Psiu
                    .padding(.trailing, geo.isOpen ? 10 : 6)   // closed: Psiu 2 points from the notch, 8 visible from the edge of the ear
                    .frame(height: geo.stripHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { app.toggleDetail(displayID) }

                    if geo.isOpen {
                        DetailView(store: store, onOpen: { store.answer($0); app.openTerminal($0) })
                            .environment(\.colorScheme, .dark)
                            .padding(.horizontal, 6)
                            // The detail comes into focus while the notch stretches.
                            .transition(.asymmetric(
                                insertion: .modifier(active: Reveal(hidden: true), identity: Reveal(hidden: false))
                                    .animation(.spring(response: 0.35, dampingFraction: 1).delay(0.04)),
                                removal: .modifier(active: Reveal(hidden: true), identity: Reveal(hidden: false))
                                    .animation(.easeIn(duration: 0.12))))
                    }
                }
                .padding(.horizontal, geo.flare)
            }
            .frame(width: geo.shapeSize.width, height: geo.shapeSize.height)
            .clipShape(NotchShape(flare: geo.flare, radius: geo.radius))
            .background {
                // Hovered or open, the notch lifts off the screen with a soft shadow.
                NotchShape(flare: geo.flare, radius: geo.radius).fill(Color.black)
                    .shadow(color: .black.opacity(geo.isOpen || geo.swollen ? 0.18 : 0), radius: 5, y: 2)
            }
            .overlay {
                if store.color == .red {
                    // Panic: a red edge pulses around the notch.
                    PanicBorder(flare: geo.flare, radius: geo.radius, paused: store.displayAsleep)
                        .allowsHitTesting(false)
                }
            }
            .onHover { app.hover(displayID, $0) }
            .contextMenu {
                Menu(tr("Mostrar em", "Show on")) {
                    ForEach(app.screenNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { app.isScreenVisible(name) },
                            set: { _ in app.toggleScreen(name) }))
                    }
                }
                Toggle(tr("Silenciar sons", "Mute sounds"), isOn: Binding(
                    get: { store.muted },
                    set: { store.muted = $0; app.savePrefs() }))
                Button(tr("Testar sons", "Test sounds")) {
                    NSSound(named: NSSound.Name(Sounds.permission))?.play()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        NSSound(named: NSSound.Name(Sounds.finished))?.play()
                    }
                }
                Divider()
                Button(tr("Sair do Psiu", "Quit Psiu")) { NSApp.terminate(nil) }
                Button(tr("Desinstalar o Psiu…", "Uninstall Psiu…")) { app.uninstall() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Hovered, the closed notch's content swells with it.
    let hoverScale: CGFloat = 1.12

    /// The usage grows in step with Psiu: hovered, and open (Psiu goes from 26 to 42 points).
    var usageScale: CGFloat { geo.isOpen ? 42.0 / 26.0 : geo.swollen ? hoverScale : 1 }

    @ViewBuilder var usage: some View {
        if let c = store.fiveHour {
            let text = "\(Int(c.pct.rounded()))%"
            Text(text)
                .modifier(UsageFont(size: 10 * usageScale))
                .foregroundStyle(c.pct >= 75 ? usageColor(c.pct) : Color.white.opacity(0.75))
                // A leading 1 sits in the middle of its digit's width: pull it back so it starts where the other digits do.
                .padding(.leading, text.hasPrefix("1") ? -usageScale : 0)
        }
    }
}

/// Blurred, a little smaller and transparent, then sharp.
struct Reveal: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? 6 : 0)
            .scaleEffect(hidden ? 0.92 : 1, anchor: .top)
            .opacity(hidden ? 0 : 1)
    }
}

/// A font size that follows the notch's spring, sharp at every step, instead of jumping.
struct UsageFont: ViewModifier, @preconcurrency Animatable {
    var size: CGFloat

    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .semibold).monospacedDigit())
    }
}
