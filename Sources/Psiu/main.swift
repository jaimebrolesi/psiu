import AppKit
import SwiftUI

// MARK: - Entry point

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "hook": runHook(); exit(0)
case "statusline": runStatusLine(); exit(0)
case "install": runInstall(); exit(0)
case "uninstall": runUninstall(); exit(0)
case "setup", "configurar": setupWithoutWindow(); exit(0)
case "dmg-background", "fundo-dmg":
    MainActor.assumeIsolated { renderDMGBackground(args.count > 2 ? args[2] : ".") }
    exit(0)
case "icon", "icone":
    MainActor.assumeIsolated { renderIcon(args.count > 2 ? args[2] : "icon.png") }
    exit(0)
default: break
}

ensureDirs()
let lockFD = open(baseDir.appendingPathComponent("psiu.lock").path, O_CREAT | O_RDWR, 0o644)
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print(tr("O Psiu já está aberto.", "Psiu is already open."))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
