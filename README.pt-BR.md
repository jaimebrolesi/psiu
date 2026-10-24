<p align="center">
  <img src="docs/icon.svg" width="128" alt="Ícone do Psiu">
</p>

<h1 align="center">Psiu</h1>

<p align="center">
  <a href="https://github.com/jaimebrolesi/psiu/actions/workflows/build.yml"><img src="https://github.com/jaimebrolesi/psiu/actions/workflows/build.yml/badge.svg" alt="Build"></a>
</p>

<p align="center">
  Um robozinho no notch do seu Mac que avisa quando o Claude Code precisa de você.<br>
  <a href="https://jaimebrolesi.github.io/psiu/pt-br.html">Site</a> · <a href="README.md">Read in English</a>
</p>

<p align="center">
  <img src="docs/hero.svg" width="820" alt="Psiu no notch alternando entre trabalhando, precisa de você, terminou e dormindo">
</p>

*"Psiu!"* é como a gente chama a atenção de alguém. É só isso que o Psiu faz.

## Por quê

Você dá uma tarefa longa ao Claude Code, vai para o navegador ou para uma reunião e esquece de voltar. Vinte minutos depois, descobre que ele estava esperando uma permissão desde o segundo minuto. O Psiu fica no notch, mostra num relance o que cada sessão está fazendo e chama você, com cor e som, quando uma sessão termina ou precisa de você.

<p align="center">
  <img src="docs/demo.gif" width="820" alt="Psiu funcionando: uma sessão trabalha, pede permissão, termina, e o notch se abre no painel">
</p>

## O que o robô mostra

<p align="center">
  <img src="docs/gestures.svg" width="900" alt="Os dez estados do robô">
</p>

| | Estado | O que significa | Som |
|---|---|---|---|
| 1 | **Azul, olhos varrendo** | O Claude está trabalhando | nenhum |
| 2 | **Azul, espiando do notch** | O turno acabou, mas ainda há shells, monitores ou subagentes rodando em segundo plano: o Psiu se esconde no notch e de vez em quando dá uma espiada | nenhum |
| 3 | **Roxo, olhos cansados** | Uma sessão trabalhando passou de 80% do contexto e está perto de compactar | nenhum |
| 4 | **Amarelo, olhos e "!" alternando** | O Claude precisa de você: uma permissão ou uma pergunta | na hora, e a cada 2 minutos; depois de 10 minutos o Psiu entra em desespero |
| 5 | **Vermelho, olhos em chamas** | Esperando você há mais de 10 minutos | Sosumi a cada minuto |
| 6 | **Queimado, olhos em X e fumaça** | Esperando há mais de 30 minutos | nenhum (ele sacode a fuligem quando você finalmente responde) |
| 7 | **Verde, sorrindo** | Terminou | depois de 3 segundos, mais um lembrete após 3 minutos se você não olhou |
| 8 | **Verde com faixa roxa** | Terminou, mas a sessão foi compactada no caminho: hora de limpar | igual ao terminou |
| 9 | **Verde apagado, olhos semicerrados** | Parado, e você já viu | nenhum |
| 10 | **Cinza, olhos em "Z z"** | Nenhuma sessão do Claude Code aberta | nenhum |

Com várias sessões abertas, o robô mostra a mais urgente: amarelo ganha do azul, que ganha do verde.

O número ao lado do robô é quanto você já usou da janela de 5 horas do seu plano.

## Um pontinho

<p align="center">
  <img src="docs/dots.svg" width="300" alt="Ponto verde ao lado do robô">
</p>

**Ponto verde:** outra sessão terminou e você não viu, enquanto o robô está mostrando algo mais urgente. Ele só aparece quando diz algo que o robô ainda não está mostrando. No MacBook, o notch se alarga um pouco enquanto o ponto está aceso, para a câmera não escondê-lo.

## O painel

Clique no notch e ele se estica para baixo, virando um painel. Clique de novo, ou em qualquer outro lugar, para recolher.

<p align="center">
  <img src="docs/panel.svg" width="760" alt="O notch se esticando para baixo e virando o painel">
</p>

- **Janela de 5 horas e semana,** com o horário de renovação. Pelo ritmo da última hora, o Psiu avisa se o consumo atual estoura a janela de 5 horas antes de ela renovar.
- **Cada sessão** (as cinco mais recentes, mais a contagem das outras), com o estado, uma linha com o resumo do que terminou ou do que está pedindo, e o uso de contexto (roxo acima de 80%, mesmo numa sessão parada). Clique na sessão para trazer a janela do terminal dela para a frente: Terminal e iTerm vão direto na aba; VS Code, Cursor e outros trazem o app.
- **Sessões compactadas** ganham a etiqueta "compactada Nx" e, quando terminam, a sugestão de limpar a sessão (`/clear`) antes do próximo pedido.
- **Hoje:** quanto tempo os agentes trabalharam, quanto tempo esperaram por você e sua resposta média, mais o acumulado de 7 dias e quantos Psius queimaram esperando você. Um espelho pequeno e honesto.

A versão instalada aparece no rodapé do painel; clique nela para abrir a página daquela versão.

No clique direito do robô: **Mostrar em** (escolhe as telas), **Silenciar sons**, **Testar sons**, **Sair do Psiu** e **Desinstalar o Psiu…**.

Em telas sem notch, como um monitor externo, o Psiu desenha um notch do mesmo tamanho no topo da tela.

## Instalar

1. Baixe o `Psiu.dmg` da [última versão](https://github.com/jaimebrolesi/psiu/releases/latest). Para conferir o download, compare `shasum -a 256 Psiu.dmg` com o `Psiu.dmg.sha256` da mesma versão.
2. Abra e arraste o Psiu para Aplicativos.

<p align="center">
  <img src="docs/dmg.svg" width="560" alt="Janela do instalador do Psiu">
</p>

3. Abra o Psiu pela pasta Aplicativos. Ele não é notarizado pela Apple, então na primeira vez o macOS vai bloquear. Vá em **Ajustes do Sistema → Privacidade e Segurança**, role até o fim e clique em **Abrir Mesmo Assim**.
4. O Psiu pergunta se pode se ligar ao Claude Code. Clique em **Ligar**: ele grava os hooks e a status line em `~/.claude/settings.json`, guardando um backup do arquivo original, e se registra para abrir no login.
5. Reinicie as sessões do Claude Code que já estavam abertas.

Requisitos: macOS 14 (Sonoma) ou mais novo, em Apple silicon ou Intel, e o Claude Code. Os números de uso do plano exigem assinatura Claude Pro ou Max.

> O Psiu fala português quando o Mac está em português do Brasil e inglês nos demais idiomas.

## Compilar a partir do código

```bash
xcode-select --install   # uma vez, para ter o compilador Swift
bash build-dmg.sh         # gera o build/Psiu.app e o Psiu.dmg nesta pasta
```

É um pacote Swift sem dependências: `Sources/PsiuCore` tem a lógica (hooks, status line, instalador e as regras por trás do robô) e `Sources/Psiu`, o app na tela. `bash test.sh` roda os testes de unidade e confere o app gerado.

## Como funciona

O Psiu usa só os pontos de extensão oficiais do Claude Code:

- Os **hooks** avisam quando uma sessão começa, recebe um pedido, usa uma ferramenta, pede permissão, é compactada, termina ou fecha. O Psiu grava o estado de cada sessão em `~/.psiu/sessions`.
- A **status line** entrega o uso de contexto de cada sessão e os limites do seu plano.
- O app lê esses arquivos duas vezes por segundo e desenha o robô.

A sua status line anterior continua funcionando: o Psiu a executa e mostra o que ela mostrava.

**Privacidade.** O Psiu nunca se conecta à internet, nunca lê senha ou token e guarda tudo em `~/.psiu`, no seu Mac. A única configuração que ele altera é o `~/.claude/settings.json`, com backup.

## Desinstalar

Clique direito no robô → **Desinstalar o Psiu…**. Ele remove os hooks e a status line (a sua status line anterior volta) e sai dos itens de login. Depois, arraste o Psiu de Aplicativos para o Lixo.

## Limitações

- Só o **Claude Code**. Os apps do Claude e o claude.ai não expõem o estado das conversas.
- Os números do plano se atualizam sempre que uma sessão do Claude Code recebe uma resposta. O Claude Code não expõe limites por modelo.
- Se você parar uma tarefa em segundo plano enquanto o Claude está ocioso, nenhum evento é disparado, e o robô fica em "segundo plano" até o próximo evento da sessão.

## Licença

O código está sob a [licença MIT](LICENSE): use, modifique e distribua. O **nome Psiu, o personagem robô e o ícone** não fazem parte da licença MIT e continuam sendo meus; se publicar um fork, dê a ele outro nome e outro personagem. Veja o [LICENSE-ASSETS.md](LICENSE-ASSETS.md).

Feito por [Jaime Brolesi](https://www.linkedin.com/in/jaimebrolesi), com o Claude.
