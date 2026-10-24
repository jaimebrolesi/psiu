import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panels: [CGDirectDisplayID: (panel: NotchPanel, host: Host, geo: PanelGeometry)] = [:]
    var timer: Timer?
    var clickMonitor: Any?
    var hiddenScreens = Set<String>()
    let springAnimation = Animation.spring(response: 0.45, dampingFraction: 0.86)

    /// Why nobody can see the robot right now (screens asleep, screen locked, another user active).
    private var hiddenReasons = Set<String>()

    private func setHidden(_ reason: String, _ hidden: Bool) {
        if hidden { hiddenReasons.insert(reason) } else { hiddenReasons.remove(reason) }
        let asleep = !hiddenReasons.isEmpty
        if store.displayAsleep != asleep { store.displayAsleep = asleep }
    }

    /// While nobody can see the robot, it stops redrawing.
    private func watchDisplayVisibility() {
        let ws = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, "sleep", true), (NSWorkspace.screensDidWakeNotification, "sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false),
        ]
        for (name, reason, hidden) in events {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHidden(reason, hidden) }
            }
        }
        for (name, hidden) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHidden("lock", hidden) }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        watchDisplayVisibility()
        let prefs = readJSON(prefsFile) ?? [:]
        store.muted = prefs["mudo"] as? Bool ?? false
        hiddenScreens = Set(prefs["ocultas"] as? [String] ?? [])

        syncPanels()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanels() }
        }
        // A click in any other app collapses the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
        store.reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.reload()
                self?.updateDotsRoom()
                self?.checkDemo()
            }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.checkInstallation() }
        }
    }

    // MARK: Demo (used by record-demo.sh)

    var openedByDemo = false

    func checkDemo() {
        let requested = fm.fileExists(atPath: baseDir.appendingPathComponent("demo-panel").path)
        if requested && !openedByDemo {
            let mainID = NSScreen.screens.first.map { displayID($0) }
            if let id = mainID.flatMap({ panels[$0] != nil ? $0 : nil }) ?? panels.keys.first {
                if panels[id]?.geo.isOpen == false { toggleDetail(id) }
                openedByDemo = true
            }
        } else if !requested && openedByDemo {
            closeAll()
            openedByDemo = false
        }
    }

    // MARK: Installation

    func showAlert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func checkInstallation() {
        if binPath.hasPrefix("/Volumes/") || binPath.contains("/AppTranslocation/") {
            _ = showAlert(tr("Arraste o Psiu para Aplicativos", "Drag Psiu to Applications"),
                      tr("Ele está rodando de dentro do instalador. Arraste o Psiu para a pasta Aplicativos e abra de lá.",
                         "It's running from inside the installer. Drag Psiu to the Applications folder and open it from there."))
            NSApp.terminate(nil)
            return
        }
        if isPsiuConnected() {
            // Installs from older versions lack newer hook events: add them quietly (the original backup is kept).
            if isMissingHooks() { runInstall() }
            return
        }
        var text = tr("O Psiu grava os hooks e a status line em ~/.claude/settings.json, guardando um backup do original, e passa a abrir quando você entra no Mac. Nada sai do seu computador.",
                       "Psiu adds its hooks and status line to ~/.claude/settings.json, keeping a backup of the original, and opens when you log in to your Mac. Nothing leaves your computer.")
        if hasFarol { text += tr("\n\nO Farol, a versão anterior, será desligado e substituído. O placar e as preferências vêm junto.",
                                  "\n\nFarol, the previous version, will be turned off and replaced. Your scoreboard and preferences come along.") }
        guard showAlert(tr("Ligar o Psiu ao Claude Code?", "Connect Psiu to Claude Code?"), text,
                    buttons: [tr("Ligar", "Connect"), tr("Agora não", "Not now")]) == 0 else { return }
        migrateFromFarol()
        runInstall()
        var doneMessage = tr("Reinicie as sessões do Claude Code que estiverem abertas.", "Restart any Claude Code sessions that are open.")
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                doneMessage += tr("\n\nPara ele abrir no login, autorize o Psiu em Ajustes do Sistema → Geral → Itens de Início.",
                          "\n\nTo open it at login, allow Psiu in System Settings → General → Login Items.")
            }
        } catch {
            doneMessage += tr("\n\nNão consegui registrar a abertura no login: ", "\n\nCouldn't register open at login: ") + error.localizedDescription
        }
        _ = showAlert(tr("Psiu ligado", "Psiu is connected"), doneMessage)
    }

    func uninstall() {
        let r = showAlert(tr("Desinstalar o Psiu?", "Uninstall Psiu?"),
                      tr("Removo os hooks e a status line do Claude Code (a sua status line anterior volta) e tiro o Psiu do login. Depois, é só arrastar o Psiu de Aplicativos para o Lixo.",
                         "I'll remove the hooks and status line from Claude Code (your previous status line comes back) and take Psiu out of your login items. Then just drag Psiu from Applications to the Trash."),
                      buttons: [tr("Desinstalar", "Uninstall"), tr("Cancelar", "Cancel")])
        guard r == 0 else { return }
        runUninstall()
        try? SMAppService.mainApp.unregister()
        try? fm.removeItem(at: baseDir)
        try? fm.removeItem(at: home.appendingPathComponent(".farol"))
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    // MARK: Screens

    var screenNames: [String] { NSScreen.screens.map(\.localizedName) }

    func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func notchWidth(_ screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let e = screen.auxiliaryTopLeftArea, let d = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, screen.frame.width - e.width - d.width)
    }

    /// On screens without a notch, Psiu mimics the MacBook's notch (or 185 points if no MacBook screen is on).
    var defaultNotchWidth: CGFloat {
        NSScreen.screens.map { notchWidth($0) }.first(where: { $0 > 0 }) ?? 185
    }

    func isScreenVisible(_ name: String) -> Bool { !hiddenScreens.contains(name) }

    func toggleScreen(_ name: String) {
        if isScreenVisible(name) {
            let remaining = screenNames.filter { isScreenVisible($0) && $0 != name }
            guard !remaining.isEmpty else { return }   // never hides from every screen
            hiddenScreens.insert(name)
        } else {
            hiddenScreens.remove(name)
        }
        savePrefs()
        syncPanels()
    }

    func savePrefs() {
        writeJSON(["mudo": store.muted, "ocultas": Array(hiddenScreens)], to: prefsFile)
    }

    func makePanel(_ id: CGDirectDisplayID) -> (panel: NotchPanel, host: Host, geo: PanelGeometry) {
        let p = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        let geo = PanelGeometry()
        let h = Host(rootView: PillView(store: store, app: self, displayID: id, geo: geo))
        p.contentView = h
        return (p, h, geo)
    }

    func syncPanels() {
        var presentIDs = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = displayID(screen)
            guard isScreenVisible(screen.localizedName) else { continue }
            presentIDs.insert(id)
            let entry = panels[id] ?? makePanel(id)
            panels[id] = entry
            place(entry, on: screen)
            entry.panel.orderFrontRegardless()
        }
        for (id, entry) in Array(panels) where !presentIDs.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
    }

    func place(_ entry: (panel: NotchPanel, host: Host, geo: PanelGeometry), on screen: NSScreen) {
        let f = screen.frame
        let notch = notchWidth(screen)
        let menuBarHeight = f.maxY - screen.visibleFrame.maxY
        entry.geo.screenFrame = f
        entry.geo.h = notch > 0 ? screen.safeAreaInsets.top : (menuBarHeight >= 20 ? menuBarHeight : 24)
        entry.geo.w = (notch > 0 ? notch : defaultNotchWidth) + 2 * 46
        entry.geo.hasNotch = notch > 0
        entry.geo.dotsRoom = dotsRoom(for: entry.geo)
        applyFrame(entry)
    }

    /// On screens with a physical notch, the closed notch widens while a dot is lit; elsewhere the dot is already visible.
    func dotsRoom(for geo: PanelGeometry) -> CGFloat {
        geo.hasNotch && store.greenDot ? PanelGeometry.dotsRoomWidth : 0
    }

    func updateDotsRoom() {
        for (id, entry) in panels {
            let target = dotsRoom(for: entry.geo)
            guard entry.geo.dotsRoom != target else { continue }
            if entry.geo.isOpen {   // the open panel doesn't depend on it
                entry.geo.dotsRoom = target
            } else if target > entry.geo.dotsRoom {
                // Growing: first the window (transparent), then the notch stretches inside it.
                let g = entry.geo, w = g.w + 2 * target
                entry.panel.setFrame(NSRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - g.h, width: w, height: g.h), display: true)
                withAnimation(springAnimation) { entry.geo.dotsRoom = target }
            } else {
                // Shrinking: the notch first, then the window.
                withAnimation(springAnimation) { entry.geo.dotsRoom = target }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let entry = self.panels[id], !entry.geo.isOpen else { return }
                        self.applyFrame(entry)
                    }
                }
            }
        }
    }

    /// Closed, the window is the size of the notch; open, the size of the panel. Always at the top, centered.
    func applyFrame(_ entry: (panel: NotchPanel, host: Host, geo: PanelGeometry)) {
        let g = entry.geo
        let w = g.isOpen ? g.W : g.closedWidth
        let h = g.isOpen ? g.H : g.h
        entry.panel.setFrame(NSRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h), display: true)
    }

    func toggleDetail(_ id: CGDirectDisplayID) {
        guard let entry = panels[id] else { return }
        if entry.geo.isOpen { closePanel(id); return }
        closeAll()
        store.acknowledge()
        let lines = CGFloat(min(max(store.sessions.count, 1), 5))
        let tips = CGFloat(store.sessions.prefix(5).filter { $0.state == .done && $0.compactions > 0 }.count)
        entry.geo.W = max(entry.geo.closedWidth, 340)
        entry.geo.H = max(entry.geo.h, PanelGeometry.openStripHeight) + 156 + 112 + 70 * lines + 16 * tips + (store.today.burnt > 0 ? 18 : 0) + 16
        // First the window grows (transparent), then the notch stretches inside it.
        let g = entry.geo
        entry.panel.setFrame(NSRect(x: g.screenFrame.midX - g.W / 2, y: g.screenFrame.maxY - g.H, width: g.W, height: g.H), display: true)
        withAnimation(springAnimation) { entry.geo.isOpen = true }
    }

    func closePanel(_ id: CGDirectDisplayID) {
        guard let entry = panels[id], entry.geo.isOpen else { return }
        withAnimation(springAnimation) { entry.geo.isOpen = false }
        // After the notch collapses, the window goes back to the notch size and frees the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let entry = self.panels[id], !entry.geo.isOpen else { return }
                self.applyFrame(entry)
            }
        }
    }

    func closeAll() {
        for id in panels.keys { closePanel(id) }
    }

    // MARK: Open the session's terminal

    func openTerminal(_ s: Session) {
        closeAll()
        let bundle = s.bundle ?? ""
        let prog = s.termprog ?? ""
        if let tty = s.tty, !tty.isEmpty {
            if bundle == "com.apple.Terminal" || prog == "Apple_Terminal" {
                if runAppleScript(scriptTerminal(tty)) { return }
            }
            if bundle == "com.googlecode.iterm2" || prog == "iTerm.app" {
                if runAppleScript(scriptITerm(tty)) { return }
            }
        }
        // Others (VS Code, Cursor, Ghostty, Warp...): bring the app to the front.
        if !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func runAppleScript(_ script: String) -> Bool {
        var errorInfo: NSDictionary?
        let r = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        return errorInfo == nil && r?.booleanValue == true
    }

    func scriptTerminal(_ tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    func scriptITerm(_ tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
