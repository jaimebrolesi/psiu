import AppKit
import PsiuCore
import SwiftUI

struct PillView: View {
    let store: Store
    let app: AppDelegate
    let displayID: CGDirectDisplayID
    let geo: PanelGeometry

    var radius: CGFloat { geo.isOpen ? 24 : 9 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius).fill(Color.black)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        usage
                        Spacer(minLength: 0)
                        if store.greenDot { Circle().fill(Palette.finishedDot).frame(width: 5, height: 5) }
                        // Peeking, the robot rests on the bottom of the strip: the clipping edge matches the notch's edge.
                        let peeking = store.color == .backgroundBlue && !geo.isOpen
                        RobotView(color: store.color, tired: store.heavyContext, peeking: peeking,
                                  bandaged: store.bandaged, revivingUntil: store.revivingUntil, relief: store.relief,
                                  paused: store.displayAsleep)
                            .aspectRatio(60.0 / 46.0, contentMode: .fit)
                            .frame(width: geo.isOpen ? 42 : 29, height: geo.isOpen ? 32 : 22)
                            .frame(maxHeight: .infinity, alignment: peeking ? .bottom : .center)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: geo.stripHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { app.toggleDetail(displayID) }

                    if geo.isOpen {
                        DetailView(store: store, onOpen: { store.answer($0); app.openTerminal($0) })
                            .environment(\.colorScheme, .dark)
                            .padding(.horizontal, 6)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -6))
                                    .animation(.easeOut(duration: 0.28).delay(0.14)),
                                removal: .opacity.animation(.easeIn(duration: 0.1))))
                    }
                }
            }
            .frame(width: geo.isOpen ? geo.W : geo.closedWidth, height: geo.isOpen ? geo.H : geo.h)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
            .overlay {
                if store.color == .red {
                    // Panic: a red edge pulses around the notch.
                    PanicBorder(radius: radius, paused: store.displayAsleep)
                        .allowsHitTesting(false)
                }
            }
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

    @ViewBuilder var usage: some View {
        if let c = store.fiveHour {
            Text("\(Int(c.pct.rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(c.pct >= 75 ? usageColor(c.pct) : Color.white.opacity(0.75))
        }
    }
}
