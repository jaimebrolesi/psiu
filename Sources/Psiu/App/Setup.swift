import Foundation
import PsiuCore
import ServiceManagement

/// `Psiu setup`: connects Psiu without a window: migrates Farol, writes hooks and status line, and registers open at login.
func setupWithoutWindow() {
    migrateFromFarol()
    runOrExit { try runInstall() }
    do {
        try SMAppService.mainApp.register()
        print(SMAppService.mainApp.status == .requiresApproval
              ? tr("Abertura no login registrada; falta autorizar em Ajustes do Sistema → Geral → Itens de Início.", "Open at login registered; approve it in System Settings → General → Login Items.")
              : tr("Abertura no login registrada.", "Open at login registered."))
    } catch {
        Log.app.error("Couldn't register open at login: \(error.localizedDescription, privacy: .public)")
        print(tr("Não consegui registrar a abertura no login: \(error.localizedDescription)", "Couldn't register open at login: \(error.localizedDescription)"))
    }
}
