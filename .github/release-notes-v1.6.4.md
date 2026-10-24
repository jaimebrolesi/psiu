**Psiu 1.6.4**: more reliable when it matters.

- Stays yellow while a subagent waits for your permission. Before, the other subagents' work and the main agent ending its turn hid the request behind blue.
- A session whose terminal was closed or whose Claude Code crashed now leaves the notch right away, instead of staying blue for up to 12 hours.
- Hooks that run at the same time (parallel tool calls) no longer overwrite each other's updates.
- If `~/.claude/settings.json` isn't valid JSON, Psiu says so in an alert instead of quitting without a word.
- Installing keeps `settings.json` in a stable order, so a versioned copy doesn't churn.
- If the status line you had before Psiu hangs, Psiu shows its own after two seconds.
- With more than five sessions, the panel counts the others ("+2 more sessions").
- Each release now comes with `Psiu.dmg.sha256` to check the download.

**Install or update:** download `Psiu.dmg` and drag Psiu into Applications, replacing the old one. Psiu adds its two new hook events to Claude Code by itself on the first launch; restart open Claude Code sessions to pick them up.

---

**Psiu 1.6.4**: mais confiável quando importa.

- Fica amarelo enquanto um subagente espera a sua permissão. Antes, o trabalho dos outros subagentes e o fim do turno do agente principal escondiam o pedido atrás do azul.
- Uma sessão cujo terminal foi fechado, ou cujo Claude Code travou, sai do notch na hora, em vez de ficar azul por até 12 horas.
- Hooks que rodam ao mesmo tempo (ferramentas em paralelo) não apagam mais a atualização um do outro.
- Se o `~/.claude/settings.json` não for um JSON válido, o Psiu avisa num alerta, em vez de fechar sem dizer nada.
- A instalação mantém o `settings.json` numa ordem estável, então uma cópia versionada não fica mudando à toa.
- Se a status line que você tinha antes do Psiu travar, o Psiu mostra a dele depois de dois segundos.
- Com mais de cinco sessões, o painel conta as outras ("+2 sessões").
- Cada versão agora vem com o `Psiu.dmg.sha256`, para conferir o download.

**Instalar ou atualizar:** baixe o `Psiu.dmg` e arraste o Psiu para Aplicativos, substituindo o antigo. O Psiu adiciona sozinho os dois eventos de hook novos ao Claude Code na primeira abertura; reinicie as sessões abertas do Claude Code para eles valerem.
