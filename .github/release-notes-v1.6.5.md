**Psiu 1.6.5**: a denied permission no longer leaves Psiu waiting for you.

- When you deny the main agent's permission with Esc, Claude Code sends no hook event, so Psiu stayed yellow and went on to panic and burn. Psiu now notices that Claude Code wrote the session's transcript after the dialog closed and shows the session as stopped. It only looks at the file's date, never at what's in it.
- While a shell or subagent runs in the background, its end also writes the transcript, so in that case Psiu keeps waiting for you as before, until Claude Code's next event.

**Install or update:** download `Psiu.dmg` and drag Psiu into Applications, replacing the old one. Restart open Claude Code sessions so their hooks record the transcript's location.

---

**Psiu 1.6.5**: uma permissão negada não deixa mais o Psiu esperando por você.

- Quando você nega com Esc a permissão do agente principal, o Claude Code não manda nenhum evento de hook, então o Psiu ficava amarelo e depois entrava em pânico e queimava. Agora o Psiu percebe que o Claude Code gravou o transcript da sessão depois que o diálogo fechou e mostra a sessão como parada. Ele só olha a data do arquivo, nunca o conteúdo.
- Enquanto um shell ou subagente roda em segundo plano, o fim dele também grava o transcript. Nesse caso o Psiu continua esperando por você como antes, até o próximo evento do Claude Code.

**Instalar ou atualizar:** baixe o `Psiu.dmg` e arraste o Psiu para Aplicativos, substituindo o antigo. Reinicie as sessões abertas do Claude Code para os hooks registrarem onde fica o transcript.
