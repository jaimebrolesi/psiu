// Psiu: robozinho que mostra o estado das sessões do Claude Code no notch do Mac.
// Um único binário com quatro modos:
//   Psiu               abre o robozinho no notch (app de barra, sem ícone no Dock)
//   Psiu hook          recebe os eventos do Claude Code (chamado pelos hooks)
//   Psiu statusline    recebe contexto e limites do plano (chamado pela status line)
//   Psiu install / uninstall   liga ou desliga o Psiu no ~/.claude/settings.json
//   Psiu icone <png>   desenha o ícone do app (usado pelo gerar-dmg.sh)
// Não acessa a internet, não lê token nem senha. Tudo fica em ~/.psiu.

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Caminhos e utilitários

let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent(".psiu")
let sessionsDir = baseDir.appendingPathComponent("sessions")
let limitsFile = baseDir.appendingPathComponent("limits.json")
let prefsFile = baseDir.appendingPathComponent("prefs.json")
let prevStatusFile = baseDir.appendingPathComponent("statusline-anterior.txt")
/// O próprio executável: /Applications/Psiu.app/Contents/MacOS/Psiu depois de instalado.
let binPath = Bundle.main.executablePath ?? CommandLine.arguments[0]

/// Reconhece comandos do Psiu e do Farol (a versão anterior), para trocar um pelo outro sem duplicar.
func ehDoPsiu(_ cmd: String) -> Bool {
    cmd.contains("/Psiu.app/Contents/MacOS/Psiu") || cmd.contains("/.farol/bin/Farol")
}

func ensureDirs() {
    try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func writeJSON(_ obj: [String: Any], to url: URL, pretty: Bool = false) {
    let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .withoutEscapingSlashes] : []
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: opts) {
        try? d.write(to: url, options: .atomic)
    }
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func safeID(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
}

// MARK: - Modo hook: estado de cada sessão

/// Junta espaços e quebras de linha e corta no tamanho pedido.
func limpar(_ texto: String, _ max: Int) -> String {
    let uma = texto.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    return uma.count > max ? String(uma.prefix(max)) + "…" : uma
}

/// Último trecho útil de uma resposta: a última linha com texto, sem marcação.
func ultimoTrecho(_ msg: String) -> String {
    let linhas = msg.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("```") && $0 != "---" }
    var ultima = linhas.last ?? ""
    ultima = ultima.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    while let c = ultima.first, "#*->|".contains(c) { ultima.removeFirst(); ultima = ultima.trimmingCharacters(in: .whitespaces) }
    return limpar(ultima, 220)
}

/// Terminal de onde a sessão roda (ex.: /dev/ttys003), para o clique trazer a janela certa.
func ttyAtual() -> String? {
    for pid in [getpid(), getppid()] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { continue }
        let d = saida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let t = (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.hasPrefix("?") { return t.hasPrefix("/dev/") ? t : "/dev/" + t }
    }
    return nil
}

func runHook() {
    ensureDirs()
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let rawID = input["session_id"] as? String else { return }
    let sid = safeID(rawID)
    guard !sid.isEmpty else { return }
    let file = sessionsDir.appendingPathComponent("\(sid).json")
    let event = input["hook_event_name"] as? String ?? ""
    let now = Date().timeIntervalSince1970

    if event == "SessionEnd" {
        try? fm.removeItem(at: file)
        try? fm.removeItem(at: sessionsDir.appendingPathComponent("\(sid).metrics.json"))
        return
    }

    var rec = readJSON(file) ?? [:]
    if rec["project"] == nil, let cwd = input["cwd"] as? String, !cwd.isEmpty {
        rec["project"] = (cwd as NSString).lastPathComponent
    }
    if rec["tty"] == nil {
        let env = ProcessInfo.processInfo.environment
        rec["bundle"] = env["__CFBundleIdentifier"]
        rec["termprog"] = env["TERM_PROGRAM"]
        rec["tty"] = ttyAtual() ?? ""
    }
    let estadoAntes = rec["state"] as? String

    var novo: String?
    switch event {
    case "SessionStart":
        novo = "idle"
    case "UserPromptSubmit":
        novo = "running"
        let pedido = input["prompt"] as? String ?? ""
        rec["resumo"] = pedido.hasPrefix("<")
            ? "Retomou depois de uma tarefa em segundo plano."
            : "Pedido: " + limpar(pedido, 140)
    case "PreToolUse", "PostToolUse":
        novo = "running"
    case "PermissionRequest":
        novo = "awaiting"
        let ferramenta = input["tool_name"] as? String ?? "uma ferramenta"
        if let cmd = (input["tool_input"] as? [String: Any])?["command"] as? String {
            rec["resumo"] = "Quer permissão para \(ferramenta): " + limpar(cmd, 90)
        } else {
            rec["resumo"] = "Quer permissão para usar \(ferramenta)."
        }
    case "Notification":
        let tipo = input["notification_type"] as? String ?? ""
        let msg = (input["message"] as? String ?? "").lowercased()
        if tipo == "permission_prompt" || tipo == "elicitation_dialog" || msg.contains("permission") {
            novo = "awaiting"
            if estadoAntes != "awaiting", let m = input["message"] as? String { rec["resumo"] = limpar(m, 140) }
        } else if tipo == "idle_prompt", rec["state"] as? String == "running" {
            // Você interrompeu com Esc: o Stop não dispara, então o idle corrige o azul preso.
            novo = "idle"
        }
    case "Stop":
        if let m = input["last_assistant_message"] as? String, !m.isEmpty { rec["resumo"] = ultimoTrecho(m) }
        // O Stop traz as tarefas ainda rodando (shells, monitores, subagentes).
        let tarefas = (input["background_tasks"] as? [[String: Any]] ?? []).filter {
            let st = $0["status"] as? String ?? "running"
            return st == "running" || st == "pending"
        }
        if tarefas.isEmpty {
            novo = "done"
            rec["bg"] = nil
        } else {
            novo = "background"
            var ordem: [String] = []
            var contagem: [String: Int] = [:]
            for t in tarefas {
                let tipo = t["type"] as? String ?? "tarefa"
                if contagem[tipo] == nil { ordem.append(tipo) }
                contagem[tipo, default: 0] += 1
            }
            rec["bg"] = ordem.map { "\(contagem[$0] ?? 0) \($0)" }.joined(separator: ", ")
        }
    default:
        break
    }

    if let s = novo {
        if rec["state"] as? String != s { rec["since"] = now }
        rec["state"] = s
    }
    rec["updated"] = now
    writeJSON(rec, to: file)
    // Nada no stdout: no UserPromptSubmit, o que sai aqui entraria no contexto do Claude.
}

// MARK: - Modo statusline: contexto e limites do plano

func runStatusLine() {
    ensureDirs()
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let input = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    let now = Date().timeIntervalSince1970

    let cw = input["context_window"] as? [String: Any]
    let ctx = num(cw?["used_percentage"])
    var partes: [String] = []

    if let rawID = input["session_id"] as? String {
        var m: [String: Any] = ["updated": now]
        if let ctx { m["ctx"] = ctx }
        if let model = (input["model"] as? [String: Any])?["display_name"] as? String { m["model"] = model }
        if let dir = (input["workspace"] as? [String: Any])?["project_dir"] as? String {
            m["project"] = (dir as NSString).lastPathComponent
        }
        writeJSON(m, to: sessionsDir.appendingPathComponent("\(safeID(rawID)).metrics.json"))
    }
    if let ctx { partes.append("contexto \(Int(ctx.rounded()))%") }

    if let rl = input["rate_limits"] as? [String: Any] {
        var lim = readJSON(limitsFile) ?? [:]
        for (chave, rotulo) in [("five_hour", "5h"), ("seven_day", "semana")] {
            guard let w = rl[chave] as? [String: Any], let p = num(w["used_percentage"]) else { continue }
            lim[chave] = ["pct": p, "resets": num(w["resets_at"]) ?? 0]
            partes.append("\(rotulo) \(Int(p.rounded()))%")
        }
        lim["updated"] = now
        writeJSON(lim, to: limitsFile)
    }

    // Se você já tinha uma status line, ela continua aparecendo no lugar da do Psiu.
    if let prev = try? String(contentsOf: prevStatusFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", prev]
        let entrada = Pipe(), saida = Pipe()
        p.standardInput = entrada
        p.standardOutput = saida
        if (try? p.run()) != nil {
            entrada.fileHandleForWriting.write(raw)
            try? entrada.fileHandleForWriting.close()
            let out = saida.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            FileHandle.standardOutput.write(out)
            return
        }
    }
    print(partes.joined(separator: " | "))
}

// MARK: - Instalar e desinstalar no settings.json do Claude Code

let settingsURL = home.appendingPathComponent(".claude/settings.json")

func carregarSettings() -> (dict: [String: Any], bruto: Data?) {
    guard let data = try? Data(contentsOf: settingsURL) else { return ([:], nil) }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        print("O ~/.claude/settings.json não é um JSON válido. Nada foi alterado.")
        exit(1)
    }
    return (obj, data)
}

/// Guarda só o backup mais antigo: o settings.json de antes do Psiu (ou do Farol). Os demais são apagados.
func backup(_ data: Data?) {
    guard let data else { return }
    let dir = settingsURL.deletingLastPathComponent()
    let prefixo = "settings.json.psiu-backup-"
    let carimbo: (String) -> Int = { Int($0.split(separator: "-").last ?? "") ?? 0 }
    let existentes = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(prefixo) || $0.hasPrefix("settings.json.farol-backup-") }
        .sorted { carimbo($0) < carimbo($1) }
    if let original = existentes.first {
        for nome in existentes.dropFirst() { try? fm.removeItem(at: dir.appendingPathComponent(nome)) }
        if existentes.count > 1 { print("Backups intermediários apagados: \(existentes.count - 1).") }
        print("Backup original preservado: \(dir.appendingPathComponent(original).path)")
        return
    }
    let url = dir.appendingPathComponent("\(prefixo)\(Int(Date().timeIntervalSince1970))")
    try? data.write(to: url)
    print("Backup do settings.json: \(url.path)")
}

func semFarol(_ grupos: [[String: Any]]) -> [[String: Any]] {
    grupos.compactMap { g in
        var g = g
        let hs = (g["hooks"] as? [[String: Any]] ?? []).filter {
            !ehDoPsiu($0["command"] as? String ?? "")
        }
        if hs.isEmpty { return nil }
        g["hooks"] = hs
        return g
    }
}

let eventosFarol: [(String, String?)] = [
    ("SessionStart", nil), ("UserPromptSubmit", nil),
    ("PreToolUse", "*"), ("PostToolUse", "*"), ("PermissionRequest", "*"),
    ("Notification", "*"), ("Stop", nil), ("SessionEnd", nil),
]

func runInstall() {
    ensureDirs()
    try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var (settings, bruto) = carregarSettings()
    backup(bruto)

    let cmdHook = "\"\(binPath)\" hook"
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for (evento, matcher) in eventosFarol {
        var grupos = semFarol(hooks[evento] as? [[String: Any]] ?? [])
        var g: [String: Any] = ["hooks": [["type": "command", "command": cmdHook]]]
        if let matcher { g["matcher"] = matcher }
        grupos.append(g)
        hooks[evento] = grupos
    }
    settings["hooks"] = hooks

    var sl = settings["statusLine"] as? [String: Any] ?? [:]
    if let cmd = sl["command"] as? String, !ehDoPsiu(cmd) {
        try? cmd.write(to: prevStatusFile, atomically: true, encoding: .utf8)
        print("Sua status line anterior foi guardada e continua aparecendo no terminal.")
    }
    sl["type"] = "command"
    sl["command"] = "\"\(binPath)\" statusline"
    settings["statusLine"] = sl

    writeJSON(settings, to: settingsURL, pretty: true)
    print("Hooks do Psiu: \(eventosFarol.map { $0.0 }.joined(separator: ", ")).")
    print("Status line do Psiu instalada. Reinicie as sessões do Claude Code abertas.")
}

func runUninstall() {
    var (settings, bruto) = carregarSettings()
    guard bruto != nil else { print("Não há settings.json. Nada a desfazer."); return }
    backup(bruto)

    if var hooks = settings["hooks"] as? [String: Any] {
        for (evento, _) in eventosFarol {
            let grupos = semFarol(hooks[evento] as? [[String: Any]] ?? [])
            hooks[evento] = grupos.isEmpty ? nil : grupos
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
    }
    if let sl = settings["statusLine"] as? [String: Any],
       ehDoPsiu(sl["command"] as? String ?? "") {
        if let prev = try? String(contentsOf: prevStatusFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            var novo = sl
            novo["command"] = prev
            settings["statusLine"] = novo
            print("Sua status line anterior foi restaurada.")
        } else {
            settings["statusLine"] = nil
        }
    }
    writeJSON(settings, to: settingsURL, pretty: true)
    print("Psiu removido do ~/.claude/settings.json.")
}

// MARK: - Primeiro uso, login e migração do Farol

/// O Psiu já está ligado ao Claude Code por este executável?
func psiuLigado() -> Bool {
    guard let data = try? Data(contentsOf: settingsURL),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cmd = (obj["statusLine"] as? [String: Any])?["command"] as? String else { return false }
    return cmd.contains(binPath)
}

var temFarol: Bool {
    fm.fileExists(atPath: home.appendingPathComponent(".farol").path)
        || fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/com.farol.app.plist").path)
}

/// Desliga o Farol (versão anterior) e traz para o Psiu o placar, as preferências e a status line guardada.
func migrarFarol() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "gui/\(getuid())/com.farol.app"]
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    try? fm.removeItem(at: home.appendingPathComponent("Library/LaunchAgents/com.farol.app.plist"))
    let velho = home.appendingPathComponent(".farol")
    guard fm.fileExists(atPath: velho.path) else { return }
    ensureDirs()
    for nome in ["placar.json", "prefs.json", "statusline-anterior.txt"] {
        let de = velho.appendingPathComponent(nome), para = baseDir.appendingPathComponent(nome)
        if fm.fileExists(atPath: de.path) && !fm.fileExists(atPath: para.path) { try? fm.copyItem(at: de, to: para) }
    }
    try? fm.removeItem(at: velho)
    // Sessões do Claude Code abertas antes da troca ainda chamam ~/.farol/bin/Farol.
    // Esse caminho passa a ser um atalho para o Psiu, então elas seguem funcionando até serem reiniciadas.
    try? fm.createDirectory(at: velho.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: velho.appendingPathComponent("bin/Farol").path, withDestinationPath: binPath)
}

/// Liga o Psiu sem janela: migra o Farol, grava hooks e status line e registra a abertura no login.
func configurarSemJanela() {
    migrarFarol()
    runInstall()
    do {
        try SMAppService.mainApp.register()
        print(SMAppService.mainApp.status == .requiresApproval
              ? "Abertura no login registrada; falta autorizar em Ajustes do Sistema → Geral → Itens de Início."
              : "Abertura no login registrada.")
    } catch {
        print("Não consegui registrar a abertura no login: \(error.localizedDescription)")
    }
}

/// Desenha o ícone do app (1024 px) com a cabeça do robô.
@MainActor
func gerarIcone(_ destino: String) {
    let view = ZStack {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(Color(hex: 0x1C1C1E))
            .frame(width: 824, height: 824)
        Canvas { g, size in desenharRobo(&g, size, .verde, false, 0) }
            .frame(width: 620, height: 475)
    }
    .frame(width: 1024, height: 1024)
    let r = ImageRenderer(content: view)
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Não consegui desenhar o ícone."); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: destino))
}

/// Fundo da janela do instalador (.dmg): 640 x 400, com seta do app para Aplicativos.
struct FundoDMG: View {
    // Centros dos ícones na janela, os mesmos que o gerar-dmg.sh usa no Finder.
    static let app = CGPoint(x: 170, y: 190)
    static let pasta = CGPoint(x: 470, y: 190)

    var body: some View {
        ZStack {
            Color(hex: 0x17181B)
            RadialGradient(colors: [Color(hex: 0x24364F, alpha: 0.6), .clear],
                           center: UnitPoint(x: 0.5, y: 0.48), startRadius: 10, endRadius: 380)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Canvas { g, size in desenharRobo(&g, size, .verde, false, 0) }
                        .frame(width: 34, height: 26)
                    Text("Psiu").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                }
                Text("Avisa quando o Claude Code precisa de você")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
            }
            .position(x: 320, y: 64)
            curva.stroke(Color(hex: 0x97C459),
                         style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
            ponta.stroke(Color(hex: 0x97C459),
                         style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Text("Arraste o Psiu para Aplicativos")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.6))
                .position(x: 320, y: 344)
        }
        .frame(width: 640, height: 400)
    }

    private let inicio = CGPoint(x: 252, y: 192)
    private let fim = CGPoint(x: 388, y: 192)
    private let controle = CGPoint(x: 320, y: 150)

    var curva: Path {
        var p = Path()
        p.move(to: inicio)
        p.addQuadCurve(to: fim, control: controle)
        return p
    }

    var ponta: Path {
        let ang = atan2(fim.y - controle.y, fim.x - controle.x)
        var p = Path()
        for desvio in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            p.move(to: fim)
            p.addLine(to: CGPoint(x: fim.x + 13 * cos(ang + desvio), y: fim.y + 13 * sin(ang + desvio)))
        }
        return p
    }
}

/// Salva o fundo do .dmg em 1x e 2x (o gerar-dmg.sh junta os dois num .tiff para telas Retina).
@MainActor
func gerarFundoDMG(_ pasta: String) {
    for (escala, nome) in [(CGFloat(1), "fundo.png"), (CGFloat(2), "fundo@2x.png")] {
        let r = ImageRenderer(content: FundoDMG())
        r.scale = escala
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("Não consegui desenhar o fundo do instalador."); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: pasta).appendingPathComponent(nome))
    }
}

// MARK: - Modelo do sinaleiro

enum Estado: String { case idle, running, background, awaiting, done }

enum Cor { case amarelo, azul, azulFundo, verde, verdeApagado, cinza }

struct Sessao: Identifiable, Equatable {
    let id: String
    var projeto: String
    var estado: Estado
    var desde: Double
    var atualizado: Double
    var ctx: Double?
    var modelo: String?
    var bg: String?
    var resumo: String?
    var tty: String?
    var bundle: String?
    var termprog: String?
}

struct Placar: Equatable {
    var trab: Double = 0      // segundos com algum agente trabalhando
    var esp: Double = 0       // segundos com alguma sessão esperando você
    var nResp: Int = 0        // quantas vezes você respondeu
    var tResp: Double = 0     // soma dos tempos até responder
}

let placarFile = baseDir.appendingPathComponent("placar.json")

struct Janela: Equatable {
    var pct: Double
    var reinicia: Double
}

// Ajuste aqui os sons e os intervalos de lembrete.
enum Sons {
    static let permissao = "Submarine"
    static let terminou = "Glass"
    static let lembretePermissaoSeg: TimeInterval = 120   // repete enquanto espera você
    static let maxLembretesPermissao = 15                 // no máximo 30 min tocando
    static let lembreteTerminouSeg: TimeInterval = 180    // um lembrete extra se você não voltou
}

@MainActor
final class Store: ObservableObject {
    @Published var sessoes: [Sessao] = []
    @Published var cincoHoras: Janela?
    @Published var semana: Janela?
    @Published var mudo = false
    @Published var hoje = Placar()
    @Published var semanaEsp: Double = 0
    @Published var previsao: Double?          // quando a janela de 5 h estoura, se for antes de renovar
    @Published var previsaoFolga = false      // o ritmo atual cabe na janela

    private var dias: [String: [String: Double]] = [:]
    private var ultimoTick: Date?
    private var ticks = 0
    private var aguardandoAntes: [String: Double] = [:]
    private var amostras: [(t: Double, p: Double)] = []
    private var resetsAtual: Double = 0
    private var ultimaLeituraLimites: Double = 0

    init() {
        if let d = readJSON(placarFile)?["dias"] as? [String: [String: Double]] { dias = d }
    }

    var contextoAlto: Bool { sessoes.contains { ($0.ctx ?? 0) >= 80 } }
    var pontoVerde: Bool {
        cor != .verde && sessoes.contains { $0.estado == .done && !vistos.contains(chave($0)) }
    }

    private var vistos = Set<String>()
    private var conhecidos = Set<String>()
    private var ultimoSom: [String: Date] = [:]
    private var lembretes: [String: Int] = [:]
    private var primeiraCarga = true

    func chave(_ s: Sessao) -> String { "\(s.id)|\(s.estado.rawValue)|\(Int(s.desde))" }

    var cor: Cor {
        if sessoes.contains(where: { $0.estado == .awaiting }) { return .amarelo }
        if sessoes.contains(where: { $0.estado == .running }) { return .azul }
        if sessoes.contains(where: { $0.estado == .background }) { return .azulFundo }
        if sessoes.contains(where: { $0.estado == .done && !vistos.contains(chave($0)) }) { return .verde }
        return sessoes.isEmpty ? .cinza : .verdeApagado
    }

    func recarregar() {
        let agora = Date().timeIntervalSince1970
        var lista: [Sessao] = []
        let arquivos = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        for url in arquivos where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".metrics.json") {
            guard let r = readJSON(url) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let metricas = sessionsDir.appendingPathComponent("\(id).metrics.json")
            let atualizado = num(r["updated"]) ?? 0
            if agora - atualizado > 12 * 3600 {   // sessão abandonada há mais de 12 h
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: metricas)
                continue
            }
            var s = Sessao(id: id,
                           projeto: r["project"] as? String ?? "sessão",
                           estado: Estado(rawValue: r["state"] as? String ?? "") ?? .idle,
                           desde: num(r["since"]) ?? atualizado,
                           atualizado: atualizado,
                           bg: r["bg"] as? String,
                           resumo: r["resumo"] as? String,
                           tty: r["tty"] as? String,
                           bundle: r["bundle"] as? String,
                           termprog: r["termprog"] as? String)
            if let m = readJSON(metricas) {
                s.ctx = num(m["ctx"])
                s.modelo = m["model"] as? String
                if r["project"] == nil, let p = m["project"] as? String { s.projeto = p }
            }
            lista.append(s)
        }
        lista.sort { $0.desde > $1.desde }
        if lista != sessoes { sessoes = lista }

        if let l = readJSON(limitsFile) {
            let c = janela(l["five_hour"], agora), w = janela(l["seven_day"], agora)
            if c != cincoHoras { cincoHoras = c }
            if w != semana { semana = w }
            registrarAmostra(l)
        }
        atualizarPlacar(Date())
        tocarSeNecessario()
        primeiraCarga = false
    }

    // MARK: Previsão da janela de 5 horas

    private func registrarAmostra(_ l: [String: Any]) {
        guard let lido = num(l["updated"]), lido != ultimaLeituraLimites,
              let fh = l["five_hour"] as? [String: Any], let p = num(fh["pct"]) else { return }
        ultimaLeituraLimites = lido
        let r = num(fh["resets"]) ?? 0
        if r != resetsAtual { amostras = []; resetsAtual = r }
        amostras.append((lido, p))
        amostras = amostras.filter { lido - $0.t <= 3600 }   // ritmo da última hora

        var estouro: Double?
        var folga = false
        if let a = amostras.first, let b = amostras.last, b.t - a.t >= 300 {
            if b.p > a.p {
                let ritmo = (b.p - a.p) / (b.t - a.t)
                let quando = b.t + (100 - b.p) / ritmo
                if resetsAtual > 0 && quando < resetsAtual { estouro = quando } else { folga = true }
            } else {
                folga = true
            }
        }
        if estouro != previsao { previsao = estouro }
        if folga != previsaoFolga { previsaoFolga = folga }
    }

    // MARK: Placar do dia

    private func chaveDia(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func atualizarPlacar(_ agora: Date) {
        let dt = min(ultimoTick.map { agora.timeIntervalSince($0) } ?? 0, 2)
        ultimoTick = agora
        let dia = chaveDia(agora)
        var d = dias[dia] ?? [:]
        if sessoes.contains(where: { $0.estado == .running || $0.estado == .background }) { d["trab", default: 0] += dt }
        if sessoes.contains(where: { $0.estado == .awaiting }) { d["esp", default: 0] += dt }

        var atuais: [String: Double] = [:]
        for s in sessoes where s.estado == .awaiting { atuais[chave(s)] = s.desde }
        for (k, desde) in aguardandoAntes where atuais[k] == nil {
            d["nResp", default: 0] += 1
            d["tResp", default: 0] += max(0, agora.timeIntervalSince1970 - desde)
        }
        aguardandoAntes = atuais
        dias[dia] = d

        let ultimos7 = (0..<7).map { chaveDia(agora.addingTimeInterval(-Double($0) * 86400)) }
        dias = dias.filter { ultimos7.contains($0.key) }
        let h = Placar(trab: (d["trab"] ?? 0).rounded(), esp: (d["esp"] ?? 0).rounded(),
                       nResp: Int(d["nResp"] ?? 0), tResp: d["tResp"] ?? 0)
        if h != hoje { hoje = h }
        let sem = ultimos7.reduce(0) { $0 + (dias[$1]?["esp"] ?? 0) }.rounded()
        if sem != semanaEsp { semanaEsp = sem }

        ticks += 1
        if ticks >= 20 {   // grava a cada ~10 s
            ticks = 0
            writeJSON(["dias": dias], to: placarFile)
        }
    }

    private func janela(_ v: Any?, _ agora: Double) -> Janela? {
        guard let d = v as? [String: Any], let p = num(d["pct"]) else { return nil }
        let r = num(d["resets"]) ?? 0
        if r > 0 && r < agora { return Janela(pct: 0, reinicia: 0) }   // janela já renovou
        return Janela(pct: p, reinicia: r)
    }

    private func tocarSeNecessario() {
        let agora = Date()
        let ativos = Set(sessoes.map(chave))
        for s in sessoes {
            let k = chave(s)
            let nova = !conhecidos.contains(k)
            conhecidos.insert(k)
            if primeiraCarga {
                ultimoSom[k] = agora
                lembretes[k] = 99
                continue
            }
            if vistos.contains(k) { continue }
            let n = lembretes[k] ?? 0
            switch s.estado {
            case .awaiting:
                if nova { tocar(Sons.permissao, k) }
                else if let u = ultimoSom[k], agora.timeIntervalSince(u) > Sons.lembretePermissaoSeg,
                        n < Sons.maxLembretesPermissao {
                    tocar(Sons.permissao, k); lembretes[k] = n + 1
                }
            case .done:
                // Espera 3 s: se outra tarefa acordar o Claude logo em seguida, não toca à toa.
                if ultimoSom[k] == nil {
                    if agora.timeIntervalSince1970 - s.desde >= 3 { tocar(Sons.terminou, k) }
                } else if let u = ultimoSom[k], agora.timeIntervalSince(u) > Sons.lembreteTerminouSeg, n < 1 {
                    tocar(Sons.terminou, k); lembretes[k] = n + 1
                }
            default:
                break
            }
        }
        conhecidos.formIntersection(ativos)
        vistos.formIntersection(ativos)
        ultimoSom = ultimoSom.filter { ativos.contains($0.key) }
        lembretes = lembretes.filter { ativos.contains($0.key) }
    }

    private func tocar(_ nome: String, _ k: String) {
        ultimoSom[k] = Date()
        if !mudo { NSSound(named: NSSound.Name(nome))?.play() }
    }

    /// Abrir o painel conta como "vi": para os lembretes sonoros.
    func reconhecer() {
        for s in sessoes where s.estado == .done || s.estado == .awaiting { vistos.insert(chave(s)) }
        objectWillChange.send()
    }
}

// MARK: - Janela no notch

final class Painel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Host: NSHostingView<PillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Geometria e estado de abertura de um painel (um por tela).
@MainActor
final class GeoPainel: ObservableObject {
    @Published var aberto = false
    @Published var w: CGFloat = 230     // fechado: largura do notch + orelhas
    @Published var h: CGFloat = 32      // fechado: altura da barra de menus
    @Published var W: CGFloat = 330     // aberto
    @Published var H: CGFloat = 260
    var tela: NSRect = .zero
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var paineis: [CGDirectDisplayID: (painel: Painel, host: Host, geo: GeoPainel)] = [:]
    var timer: Timer?
    var monitorCliques: Any?
    var telasOcultas = Set<String>()
    let mola = Animation.spring(response: 0.45, dampingFraction: 0.86)

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        let prefs = readJSON(prefsFile) ?? [:]
        store.mudo = prefs["mudo"] as? Bool ?? false
        telasOcultas = Set(prefs["ocultas"] as? [String] ?? [])

        sincronizarPaineis()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sincronizarPaineis() }
        }
        // Clique em qualquer outro app recolhe o painel.
        monitorCliques = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.fecharTodos() }
        }
        store.recarregar()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.recarregar()
                self?.verificarDemo()
            }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.verificarInstalacao() }
        }
    }

    // MARK: Demonstração (usada pelo gravar-demo.sh)

    var abertoPelaDemo = false

    func verificarDemo() {
        let pedido = fm.fileExists(atPath: baseDir.appendingPathComponent("demo-painel").path)
        if pedido && !abertoPelaDemo {
            let principal = NSScreen.screens.first.map { idTela($0) }
            if let id = principal.flatMap({ paineis[$0] != nil ? $0 : nil }) ?? paineis.keys.first {
                if paineis[id]?.geo.aberto == false { alternarDetalhe(id) }
                abertoPelaDemo = true
            }
        } else if !pedido && abertoPelaDemo {
            fecharTodos()
            abertoPelaDemo = false
        }
    }

    // MARK: Instalação

    func aviso(_ titulo: String, _ texto: String, botoes: [String] = ["OK"]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = titulo
        a.informativeText = texto
        for b in botoes { a.addButton(withTitle: b) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func verificarInstalacao() {
        if binPath.hasPrefix("/Volumes/") || binPath.contains("/AppTranslocation/") {
            _ = aviso("Arraste o Psiu para Aplicativos",
                      "Ele está rodando de dentro do instalador. Arraste o Psiu para a pasta Aplicativos e abra de lá.")
            NSApp.terminate(nil)
            return
        }
        guard !psiuLigado() else { return }
        var texto = "O Psiu grava os hooks e a status line em ~/.claude/settings.json, guardando um backup do original, e passa a abrir quando você entra no Mac. Nada sai do seu computador."
        if temFarol { texto += "\n\nO Farol, a versão anterior, será desligado e substituído. O placar e as preferências vêm junto." }
        guard aviso("Ligar o Psiu ao Claude Code?", texto, botoes: ["Ligar", "Agora não"]) == 0 else { return }
        migrarFarol()
        runInstall()
        var fim = "Reinicie as sessões do Claude Code que estiverem abertas."
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                fim += "\n\nPara ele abrir no login, autorize o Psiu em Ajustes do Sistema → Geral → Itens de Início."
            }
        } catch {
            fim += "\n\nNão consegui registrar a abertura no login: \(error.localizedDescription)"
        }
        _ = aviso("Psiu ligado", fim)
    }

    func desinstalar() {
        let r = aviso("Desinstalar o Psiu?",
                      "Removo os hooks e a status line do Claude Code (a sua status line anterior volta) e tiro o Psiu do login. Depois, é só arrastar o Psiu de Aplicativos para o Lixo.",
                      botoes: ["Desinstalar", "Cancelar"])
        guard r == 0 else { return }
        runUninstall()
        try? SMAppService.mainApp.unregister()
        try? fm.removeItem(at: baseDir)
        try? fm.removeItem(at: home.appendingPathComponent(".farol"))
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    // MARK: Telas

    var telas: [String] { NSScreen.screens.map(\.localizedName) }

    func idTela(_ tela: NSScreen) -> CGDirectDisplayID {
        (tela.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func larguraNotch(_ tela: NSScreen) -> CGFloat {
        guard tela.safeAreaInsets.top > 0,
              let e = tela.auxiliaryTopLeftArea, let d = tela.auxiliaryTopRightArea else { return 0 }
        return max(0, tela.frame.width - e.width - d.width)
    }

    /// Nas telas sem notch, o Psiu imita o notch do MacBook (ou 185 pontos, se não houver MacBook aberto).
    var larguraNotchPadrao: CGFloat {
        NSScreen.screens.map { larguraNotch($0) }.first(where: { $0 > 0 }) ?? 185
    }

    func visivel(_ nome: String) -> Bool { !telasOcultas.contains(nome) }

    func alternarTela(_ nome: String) {
        if visivel(nome) {
            let restantes = telas.filter { visivel($0) && $0 != nome }
            guard !restantes.isEmpty else { return }   // nunca esconde de todas as telas
            telasOcultas.insert(nome)
        } else {
            telasOcultas.remove(nome)
        }
        salvarPrefs()
        sincronizarPaineis()
    }

    func salvarPrefs() {
        writeJSON(["mudo": store.mudo, "ocultas": Array(telasOcultas)], to: prefsFile)
    }

    func criarPainel(_ id: CGDirectDisplayID) -> (painel: Painel, host: Host, geo: GeoPainel) {
        let p = Painel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        let geo = GeoPainel()
        let h = Host(rootView: PillView(store: store, app: self, tela: id, geo: geo))
        p.contentView = h
        return (p, h, geo)
    }

    func sincronizarPaineis() {
        var presentes = Set<CGDirectDisplayID>()
        for tela in NSScreen.screens {
            let id = idTela(tela)
            guard visivel(tela.localizedName) else { continue }
            presentes.insert(id)
            let par = paineis[id] ?? criarPainel(id)
            paineis[id] = par
            posicionar(par, em: tela)
            par.painel.orderFrontRegardless()
        }
        for (id, par) in Array(paineis) where !presentes.contains(id) {
            par.painel.orderOut(nil)
            paineis[id] = nil
        }
    }

    func posicionar(_ par: (painel: Painel, host: Host, geo: GeoPainel), em tela: NSScreen) {
        let f = tela.frame
        let notch = larguraNotch(tela)
        let alturaMenu = f.maxY - tela.visibleFrame.maxY
        par.geo.tela = f
        par.geo.h = notch > 0 ? tela.safeAreaInsets.top : (alturaMenu >= 20 ? alturaMenu : 24)
        par.geo.w = (notch > 0 ? notch : larguraNotchPadrao) + 2 * 46
        aplicarMoldura(par)
    }

    /// Fechado, a janela tem o tamanho do notch; aberta, o tamanho do painel. Sempre colada no topo, centralizada.
    func aplicarMoldura(_ par: (painel: Painel, host: Host, geo: GeoPainel)) {
        let g = par.geo
        let w = g.aberto ? g.W : g.w
        let h = g.aberto ? g.H : g.h
        par.painel.setFrame(NSRect(x: g.tela.midX - w / 2, y: g.tela.maxY - h, width: w, height: h), display: true)
    }

    func alternarDetalhe(_ id: CGDirectDisplayID) {
        guard let par = paineis[id] else { return }
        if par.geo.aberto { fechar(id); return }
        fecharTodos()
        store.reconhecer()
        let linhas = CGFloat(min(max(store.sessoes.count, 1), 5))
        par.geo.W = max(par.geo.w, 340)
        par.geo.H = par.geo.h + 156 + 112 + 70 * linhas
        // Primeiro a janela cresce (transparente), depois o notch se estica dentro dela.
        let g = par.geo
        par.painel.setFrame(NSRect(x: g.tela.midX - g.W / 2, y: g.tela.maxY - g.H, width: g.W, height: g.H), display: true)
        withAnimation(mola) { par.geo.aberto = true }
    }

    func fechar(_ id: CGDirectDisplayID) {
        guard let par = paineis[id], par.geo.aberto else { return }
        withAnimation(mola) { par.geo.aberto = false }
        // Depois que o notch se recolhe, a janela volta ao tamanho do notch e libera a barra de menus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let par = self.paineis[id], !par.geo.aberto else { return }
                self.aplicarMoldura(par)
            }
        }
    }

    func fecharTodos() {
        for id in paineis.keys { fechar(id) }
    }

    // MARK: Abrir o terminal da sessão

    func abrirTerminal(_ s: Sessao) {
        fecharTodos()
        let bundle = s.bundle ?? ""
        let prog = s.termprog ?? ""
        if let tty = s.tty, !tty.isEmpty {
            if bundle == "com.apple.Terminal" || prog == "Apple_Terminal" {
                if rodarAppleScript(scriptTerminal(tty)) { return }
            }
            if bundle == "com.googlecode.iterm2" || prog == "iTerm.app" {
                if rodarAppleScript(scriptITerm(tty)) { return }
            }
        }
        // Outros (VS Code, Cursor, Ghostty, Warp...): traz o app para a frente.
        if !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func rodarAppleScript(_ fonte: String) -> Bool {
        var erro: NSDictionary?
        let r = NSAppleScript(source: fonte)?.executeAndReturnError(&erro)
        return erro == nil && r?.booleanValue == true
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

// MARK: - Visual

func corSwiftUI(_ c: Cor) -> Color {
    switch c {
    case .amarelo: return Color(red: 1.0, green: 0.80, blue: 0.10)
    case .azul, .azulFundo: return Color(red: 0.25, green: 0.60, blue: 1.0)
    case .verde: return Color(red: 0.20, green: 0.85, blue: 0.40)
    case .verdeApagado: return Color(red: 0.20, green: 0.85, blue: 0.40).opacity(0.35)
    case .cinza: return Color.gray.opacity(0.35)
    }
}

func corEstado(_ e: Estado) -> Color {
    switch e {
    case .awaiting: return corSwiftUI(.amarelo)
    case .running, .background: return corSwiftUI(.azul)
    case .done: return corSwiftUI(.verde)
    case .idle: return corSwiftUI(.verdeApagado)
    }
}

func corUso(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 75 ? .orange : Color(red: 0.20, green: 0.75, blue: 0.40)
}

struct PillView: View {
    @ObservedObject var store: Store
    let app: AppDelegate
    let tela: CGDirectDisplayID
    @ObservedObject var geo: GeoPainel

    var raio: CGFloat { geo.aberto ? 24 : 9 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: raio, bottomTrailingRadius: raio).fill(Color.black)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        uso
                        Spacer(minLength: 0)
                        if store.pontoVerde || store.contextoAlto {
                            VStack(spacing: 3) {
                                if store.pontoVerde { Circle().fill(Color(hex: 0x97C459)).frame(width: 5, height: 5) }
                                if store.contextoAlto { Circle().fill(Color(hex: 0xE24B4A)).frame(width: 5, height: 5) }
                            }
                        }
                        RoboView(cor: store.cor, cansado: store.contextoAlto).frame(width: 29, height: 22)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: geo.h)
                    .contentShape(Rectangle())
                    .onTapGesture { app.alternarDetalhe(tela) }

                    if geo.aberto {
                        DetalheView(store: store, aoAbrir: { app.abrirTerminal($0) })
                            .environment(\.colorScheme, .dark)
                            .padding(.horizontal, 6)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -6))
                                    .animation(.easeOut(duration: 0.28).delay(0.14)),
                                removal: .opacity.animation(.easeIn(duration: 0.1))))
                    }
                }
            }
            .frame(width: geo.aberto ? geo.W : geo.w, height: geo.aberto ? geo.H : geo.h)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: raio, bottomTrailingRadius: raio))
            .contextMenu {
                Menu("Mostrar em") {
                    ForEach(app.telas, id: \.self) { nome in
                        Toggle(nome, isOn: Binding(
                            get: { app.visivel(nome) },
                            set: { _ in app.alternarTela(nome) }))
                    }
                }
                Toggle("Silenciar sons", isOn: Binding(
                    get: { store.mudo },
                    set: { store.mudo = $0; app.salvarPrefs() }))
                Button("Testar sons") {
                    NSSound(named: NSSound.Name(Sons.permissao))?.play()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        NSSound(named: NSSound.Name(Sons.terminou))?.play()
                    }
                }
                Divider()
                Button("Sair do Psiu") { NSApp.terminate(nil) }
                Button("Desinstalar o Psiu…") { app.desinstalar() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder var uso: some View {
        if let c = store.cincoHoras {
            Text("\(Int(c.pct.rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(c.pct >= 75 ? corUso(c.pct) : Color.white.opacity(0.75))
        }
    }
}

// MARK: - Robozinho

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Cabeça de robô com olhos de LED. Desenhada numa grade de 60 x 46.
struct RoboView: View {
    let cor: Cor
    var cansado = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in desenharRobo(&g, size, cor, cansado, t) }
        }
        .aspectRatio(60.0 / 46.0, contentMode: .fit)
    }
}

private func fase(_ t: Double, _ periodo: Double) -> Double {
    t.truncatingRemainder(dividingBy: periodo) / periodo
}

private func pastilha(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
                      escalaY: CGFloat = 1, dx: CGFloat = 0) -> Path {
    let nh = h * escalaY
    let cy = y + h / 2
    return Path(roundedRect: CGRect(x: x + dx, y: cy - nh / 2, width: w, height: nh),
                cornerRadius: min(r, nh / 2))
}

private func casca() -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 30, y: 6.5))
    p.addCurve(to: CGPoint(x: 55, y: 25), control1: CGPoint(x: 46, y: 6.5), control2: CGPoint(x: 55, y: 13))
    p.addCurve(to: CGPoint(x: 30, y: 43), control1: CGPoint(x: 55, y: 37), control2: CGPoint(x: 46, y: 43))
    p.addCurve(to: CGPoint(x: 5, y: 25), control1: CGPoint(x: 14, y: 43), control2: CGPoint(x: 5, y: 37))
    p.addCurve(to: CGPoint(x: 30, y: 6.5), control1: CGPoint(x: 5, y: 13), control2: CGPoint(x: 14, y: 6.5))
    p.closeSubpath()
    return p
}

private func viseira() -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 30, y: 9.2))
    p.addCurve(to: CGPoint(x: 52.3, y: 25), control1: CGPoint(x: 44, y: 9.2), control2: CGPoint(x: 52.3, y: 14.8))
    p.addCurve(to: CGPoint(x: 30, y: 40.3), control1: CGPoint(x: 52.3, y: 35.2), control2: CGPoint(x: 44, y: 40.3))
    p.addCurve(to: CGPoint(x: 7.7, y: 25), control1: CGPoint(x: 16, y: 40.3), control2: CGPoint(x: 7.7, y: 35.2))
    p.addCurve(to: CGPoint(x: 30, y: 9.2), control1: CGPoint(x: 7.7, y: 14.8), control2: CGPoint(x: 16, y: 9.2))
    p.closeSubpath()
    return p
}

/// Olhos caídos de cansaço (contexto alto), com uma gota de suor ao lado.
private func olhosCansados(_ g: inout GraphicsContext, _ led: Color, dx: CGFloat, _ t: Double) {
    let caida = CGFloat(1 - 0.1 * (1 - cos(2 * .pi * t / 2.6)) / 2)
    for (cx, angulo) in [(CGFloat(20.5), -7.0), (CGFloat(39.5), 7.0)] {
        var gg = g
        gg.translateBy(x: cx + dx, y: 26.5)
        gg.rotate(by: .degrees(angulo))
        gg.fill(pastilha(-6.5, -5, 13, 10, 4.4, escalaY: caida), with: .color(led))
    }
    let p = fase(t, 1.6)
    let y = CGFloat(-2 + 11 * p)
    let alfa = p < 0.2 ? p / 0.2 : (p > 0.8 ? (1 - p) / 0.2 : 1)
    var gota = Path()
    gota.move(to: CGPoint(x: 53, y: 7 + y))
    gota.addCurve(to: CGPoint(x: 57, y: 14.8 + y), control1: CGPoint(x: 56, y: 11 + y), control2: CGPoint(x: 57, y: 13 + y))
    gota.addCurve(to: CGPoint(x: 53, y: 18.4 + y), control1: CGPoint(x: 57, y: 17 + y), control2: CGPoint(x: 55.2, y: 18.4 + y))
    gota.addCurve(to: CGPoint(x: 49, y: 14.8 + y), control1: CGPoint(x: 50.8, y: 18.4 + y), control2: CGPoint(x: 49, y: 17 + y))
    gota.addCurve(to: CGPoint(x: 53, y: 7 + y), control1: CGPoint(x: 49, y: 13 + y), control2: CGPoint(x: 50, y: 11 + y))
    g.fill(gota, with: .color(Color(hex: 0xB5D4F4, alpha: alfa)))
}

private func desenharRobo(_ g: inout GraphicsContext, _ size: CGSize, _ cor: Cor, _ cansado: Bool, _ t: Double) {
    let s = min(size.width / 60, size.height / 46)
    g.translateBy(x: (size.width - 60 * s) / 2, y: (size.height - 46 * s) / 2)
    g.scaleBy(x: s, y: s)

    // Cores da casca e do LED por estado.
    let shell: Color, led: Color
    switch cor {
    case .azul, .azulFundo: shell = Color(hex: 0x85B7EB); led = Color(hex: 0xA9D2FF)
    case .amarelo: shell = Color(hex: 0xFAC775); led = Color(hex: 0xFFD27A)
    case .verde: shell = Color(hex: 0xC0DD97); led = Color(hex: 0xC7EE8F)
    case .verdeApagado: shell = Color(hex: 0xC0DD97, alpha: 0.5); led = Color(hex: 0xC7EE8F, alpha: 0.5)
    case .cinza: shell = Color(hex: 0x888780); led = Color(hex: 0xD3D1C7)
    }

    // Movimento da cabeça.
    var dy = 0.0, giro = 0.0
    switch cor {
    case .amarelo:
        let w = sin(2 * .pi * t / 0.9)
        giro = 5 * w
        dy = -3 * abs(w)
    case .verde:
        let p = fase(t, 1.5)
        dy = p < 0.6 ? -5 * sin(.pi * p / 0.6) : 0
    case .cinza:
        dy = 1.5 * (1 - cos(2 * .pi * t / 3.2)) / 2
    default:
        break
    }
    g.translateBy(x: 30, y: 25 + dy)
    g.rotate(by: .degrees(giro))
    g.translateBy(x: -30, y: -25)

    g.fill(casca(), with: .color(shell))
    g.fill(viseira(), with: .color(Color(hex: 0x141414)))

    // Olhos de LED.
    switch cor {
    case .azul:   // concentrado, varrendo de um lado para o outro
        let dx = CGFloat(3 * sin(2 * .pi * t / 1.3))
        if cansado { olhosCansados(&g, led, dx: dx, t); break }
        g.fill(pastilha(14, 18.4, 13, 12.8, 5, dx: dx), with: .color(led))
        g.fill(pastilha(33, 18.4, 13, 12.8, 5, dx: dx), with: .color(led))

    case .azulFundo:   // de olho no que roda em segundo plano: varre devagar e pisca
        let dx = CGFloat(3 * sin(2 * .pi * t / 4))
        if cansado { olhosCansados(&g, led, dx: dx, t); break }
        let p = fase(t, 4)
        let pisca: CGFloat = (p > 0.9 && p < 0.95) ? 0.12 : 1
        g.fill(pastilha(14, 18.4, 13, 12.8, 5, escalaY: pisca, dx: dx), with: .color(led))
        g.fill(pastilha(33, 18.4, 13, 12.8, 5, escalaY: pisca, dx: dx), with: .color(led))

    case .amarelo:   // olhos e exclamação alternando
        if Int(t / 0.8) % 2 == 0 {
            g.fill(pastilha(14, 16, 13, 17.4, 5.6), with: .color(led))
            g.fill(pastilha(33, 16, 13, 17.4, 5.6), with: .color(led))
        } else {
            g.fill(pastilha(26, 13, 8, 15.2, 4), with: .color(led))
            g.fill(Path(ellipseIn: CGRect(x: 26, y: 29.4, width: 8, height: 8)), with: .color(led))
        }

    case .verde:   // sorrindo
        var arcos = Path()
        arcos.move(to: CGPoint(x: 15, y: 29)); arcos.addQuadCurve(to: CGPoint(x: 26, y: 29), control: CGPoint(x: 20.5, y: 18))
        arcos.move(to: CGPoint(x: 34, y: 29)); arcos.addQuadCurve(to: CGPoint(x: 45, y: 29), control: CGPoint(x: 39.5, y: 18))
        g.stroke(arcos, with: .color(led), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))

    case .verdeApagado:   // semicerrado, piscando devagar
        if cansado { olhosCansados(&g, led, dx: 0, t); break }
        let p = fase(t, 5)
        let pisca: CGFloat = (p > 0.9 && p < 0.96) ? 0.12 : 1
        g.fill(pastilha(14, 21.6, 13, 8.6, 4, escalaY: pisca), with: .color(led))
        g.fill(pastilha(33, 21.6, 13, 8.6, 4, escalaY: pisca), with: .color(led))

    case .cinza:   // dormindo: Z z acendendo alternados
        let onda = cos(2 * .pi * t / 2.4)
        var zg = Path()
        zg.addLines([CGPoint(x: 15, y: 17), CGPoint(x: 26, y: 17), CGPoint(x: 15, y: 32), CGPoint(x: 26, y: 32)])
        var zp = Path()
        zp.addLines([CGPoint(x: 35, y: 22), CGPoint(x: 44, y: 22), CGPoint(x: 35, y: 32), CGPoint(x: 44, y: 32)])
        g.stroke(zg, with: .color(led.opacity(0.675 + 0.325 * onda)),
                 style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        g.stroke(zp, with: .color(led.opacity(0.675 - 0.325 * onda)),
                 style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
    }
}

func duracao(_ seg: Double) -> String {
    let m = Int(seg / 60)
    if m >= 60 { return "\(m / 60)h \(m % 60)min" }
    if m >= 1 { return "\(m) min" }
    return "\(Int(seg)) s"
}

func horaCurta(_ epoch: Double, _ formato: String = "HH'h'mm") -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "pt_BR")
    f.dateFormat = formato
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

struct DetalheView: View {
    @ObservedObject var store: Store
    var aoAbrir: (Sessao) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LimiteView(titulo: "Sessão de 5 horas", janela: store.cincoHoras, formato: "HH:mm",
                       estouro: store.previsao, folga: store.previsaoFolga)
            LimiteView(titulo: "Semana", janela: store.semana, formato: "EEE HH:mm")
            Divider()
            if store.sessoes.isEmpty {
                Text("Nenhuma sessão do Claude Code aberta.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(store.sessoes.prefix(5)) { s in
                    SessaoView(s: s)
                        .contentShape(Rectangle())
                        .onTapGesture { aoAbrir(s) }
                }
            }
            Divider()
            PlacarView(hoje: store.hoje, semanaEsp: store.semanaEsp)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimiteView: View {
    let titulo: String
    let janela: Janela?
    let formato: String
    var estouro: Double? = nil
    var folga = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(titulo).font(.system(size: 12, weight: .medium))
                Spacer()
                if let j = janela {
                    Text("\(Int(j.pct.rounded()))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            if let j = janela {
                GeometryReader { geo in
                    let w = geo.size.width
                    let usado = w * CGFloat(min(j.pct, 100) / 100)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        if estouro != nil {
                            Rectangle().fill(Color(hex: 0xEF9F27, alpha: 0.4))
                                .frame(width: max(0, w - usado)).offset(x: usado)
                        }
                        Capsule().fill(corUso(j.pct)).frame(width: usado)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                HStack {
                    Text(renovacao(j)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let e = estouro {
                        Text("No ritmo atual, acaba às \(horaCurta(e))")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xFAC775))
                    } else if folga {
                        Text("No ritmo atual, dá folga").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Aparece depois da primeira resposta numa sessão.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    func renovacao(_ j: Janela) -> String {
        guard j.reinicia > 0 else { return "Janela renovada" }
        return "Renova \(horaCurta(j.reinicia, formato))"
    }
}

struct SessaoView: View {
    let s: Sessao

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(corEstado(s.estado)).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.projeto).font(.system(size: 12, weight: .semibold))
                    Text(rotulo).font(.system(size: 10)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                if let r = s.resumo, !r.isEmpty {
                    Text(r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let c = s.ctx {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("contexto \(Int(c.rounded()))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(c >= 80 ? Color(hex: 0xE24B4A) : (c >= 70 ? Color.orange : Color.secondary))
                    ProgressView(value: min(c, 100), total: 100)
                        .tint(c >= 80 ? Color(hex: 0xE24B4A) : corUso(c)).frame(width: 60)
                }
            }
        }
    }

    var rotulo: String {
        let agora = Date().timeIntervalSince1970
        let minutos = Int((agora - s.desde) / 60)
        let ha = minutos < 1 ? "agora" : "há \(minutos) min"
        switch s.estado {
        case .running:
            let silencio = Int((agora - s.atualizado) / 60)
            return silencio >= 10 ? "· trabalhando, sem sinal há \(silencio) min" : "· trabalhando, \(ha)"
        case .background: return "· em segundo plano: \(s.bg ?? "tarefas")"
        case .awaiting: return "· precisa de você, \(ha)"
        case .done: return "· terminou, \(ha)"
        case .idle: return "· parado, \(ha)"
        }
    }
}

struct PlacarView: View {
    let hoje: Placar
    let semanaEsp: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hoje").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("7 dias: esperou você \(duracao(semanaEsp))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                metrica("Agente trabalhando", duracao(hoje.trab), nil)
                metrica("Esperando você", duracao(hoje.esp), Color(hex: 0xFAC775))
                metrica("Sua resposta média",
                        hoje.nResp > 0 ? duracao(hoje.tResp / Double(hoje.nResp)) : "sem dados", nil)
            }
            let total = hoje.trab + hoje.esp
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color(hex: 0x378ADD)).frame(width: geo.size.width * CGFloat(hoje.trab / total))
                        Rectangle().fill(Color(hex: 0xEF9F27))
                    }
                }
                .frame(height: 5)
                .clipShape(Capsule())
            }
        }
    }

    func metrica(_ rotulo: String, _ valor: String, _ cor: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rotulo).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(valor).font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(cor ?? Color.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Entrada

let argumentos = CommandLine.arguments
switch argumentos.count > 1 ? argumentos[1] : "" {
case "hook": runHook(); exit(0)
case "statusline": runStatusLine(); exit(0)
case "install": runInstall(); exit(0)
case "uninstall": runUninstall(); exit(0)
case "configurar": configurarSemJanela(); exit(0)
case "fundo-dmg":
    MainActor.assumeIsolated { gerarFundoDMG(argumentos.count > 2 ? argumentos[2] : ".") }
    exit(0)
case "icone":
    MainActor.assumeIsolated { gerarIcone(argumentos.count > 2 ? argumentos[2] : "icone.png") }
    exit(0)
default: break
}

ensureDirs()
let lockFD = open(baseDir.appendingPathComponent("psiu.lock").path, O_CREAT | O_RDWR, 0o644)
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print("O Psiu já está aberto.")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
