// Psiu: a tiny robot in the Mac's notch that shows the state of your Claude Code sessions.
// One binary with several modes:
//   Psiu               opens the robot in the notch (menu bar app, no Dock icon)
//   Psiu hook          receives Claude Code events (called by the hooks)
//   Psiu statusline    receives context and plan limits (called by the status line)
//   Psiu install / uninstall   adds or removes Psiu in ~/.claude/settings.json
//   Psiu setup         connects Psiu without a window: migrates Farol, writes hooks and status line, opens at login
//   Psiu icon <png>    draws the app icon (used by build-dmg.sh)
//   Psiu dmg-background <dir>   draws the installer background (used by build-dmg.sh)
// The Portuguese mode names of earlier versions (configurar, icone, fundo-dmg) still work.
// No internet access, never reads tokens or passwords. Everything stays in ~/.psiu.
// The command-line modes and the logic live in PsiuCore; this target is the app on screen.

import AppKit
import PsiuCore

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

let paths = PsiuPaths.current
paths.ensureDirectories()
let lockFD = open(paths.lock.path, O_CREAT | O_RDWR, 0o644)
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print(tr("O Psiu já está aberto.", "Psiu is already open."))
    exit(0)
}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
