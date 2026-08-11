# Custom CDP Browser

Painel macOS e roteador de links para os perfis Chrome e Helium persistentes do Gabriel.

O app não controla processos ou locks diretamente. Ele usa o supervisor local em `127.0.0.1:8787` como autoridade única para iniciar, consultar, abrir URLs, liberar workers e encerrar perfis.

## Linux app

A implementação Linux fica em `apps/linux`, usando Rust/Tauri/Svelte e a mesma control API v1 do app macOS. Ela não mantém launcher, inspeção de processo ou limpeza de lock próprios. Veja `apps/linux/README.md`.

## Profiles

| Name | Browser | Profile root | Profile directory | Port | Default URL |
|---|---|---|---|---:|---|
| Pessoal | Google Chrome | `~/.chrome-cdp/pessoal` | `Default` | `9224` | none |
| Central ES | Helium | `~/.chrome-cdp/central-es` | `Default` | `9222` | WhatsApp Web |
| Central RJ | Helium | `~/.chrome-cdp/central-rj` | `Default` | `9223` | WhatsApp Web |
| Financeiro/CentralSP | Helium | `~/.chrome-cdp/financeiro-centralsp-helium` | `Profile 1` | `9226` | WhatsApp Web |

The launcher also includes a **Google Chrome normal** action below the CDP profiles. It opens or activates the regular Chrome app without `--user-data-dir`, so Chrome's own profile picker and non-CDP profiles stay available even while the controlled CDP Chrome is running.

## Development

```bash
swift run
```

The overlay shortcut is `Ctrl+Shift+Z`.

## Build the app

```bash
scripts/build-app.sh
open .build/app/Custom-CDP-Browser.app
```

## Validate from Ubuntu on the Mac

This repo can use the Mac mini as a disposable Apple executor while Ubuntu stays the source of truth:

```bash
scripts/apple-remote-doctor.sh
scripts/apple-remote-macos-check.sh
```

Defaults use `mac-mini`, mirror the checkout to `/Volumes/SSD1TB/Projetos/Browser-CDP-Custom-linux-mirror`, then run `swift build`, `swift test`, and `scripts/build-app.sh` on macOS. Override machine-specific values by copying `scripts/apple-remote.env.example` to `.apple-remote.env`.

## Use as the default browser

Build and open the packaged app:

```bash
scripts/build-app.sh
open .build/app/Custom-CDP-Browser.app
```

Open Settings from the overlay and use **Set as Default Browser**. This relies on the generated `.app` declaring `http` and `https` handlers, so `swift run` is useful for development but is not a reliable default-browser validation path.

The **Open links:** setting controls links opened from outside the app:

| Mode | Behavior |
|---|---|
| Always Ask | Shows the overlay for every incoming link and lets you pick a profile. |
| Pessoal | Opens incoming links directly in the Pessoal CDP profile. |
| Last Selected | Opens incoming links in the last profile selected from the launcher, falling back to Pessoal. |

Links recebidos são enviados ao endpoint autenticado do supervisor. O supervisor garante que o perfil esteja pronto e abre a nova aba sob uma lease exclusiva curta.

## Gateway MCP/CDP

Codex e este app compartilham o supervisor leve em `http://127.0.0.1:8787`. O LaunchAgent `com.gabrielalonso.gabriel-browsers-mcp` mantém somente o gateway pai ativo; workers Playwright/CDP continuam sendo criados sob demanda.

| Path | Purpose |
|---|---|
| `/health` | Informa versão e capacidades do supervisor. |
| `/v1/profiles` | Manifesto efetivo, estado dos browsers, workers e leases. |
| `/v1/profiles/:id/start` | Inicia o perfil de forma serializada e segura. |
| `/v1/profiles/:id/stop` | Encerra somente quando não há lease/chamada ativa. |
| `/v1/profiles/:id/open-url` | Abre uma aba sob lease exclusiva curta. |
| `/v1/profiles/:id/worker/release` | Libera o worker sem fechar o browser. |
| `/mcp` | Unified MCP server `gabriel-browsers`; tools receive a `profile` argument. |
| `/pessoal/mcp` | Compatibility alias for `playwright-cdp-pessoal`. |
| `/central-es/mcp` | Compatibility alias for `playwright-cdp-es`. |
| `/central-rj/mcp` | Compatibility alias for `playwright-cdp-rj`. |
| `/financeiro-centralsp/mcp` | Compatibility alias for `playwright-cdp-financeiro-centralsp`. |
| `/workers`, `/release` | Compatibilidade com clientes antigos. |

The gateway binds to `127.0.0.1`, validates loopback `Host`, and requires `Authorization: Bearer $GABRIEL_BROWSERS_MCP_TOKEN` for MCP/admin endpoints. The token lives in `~/.codex/gabriel-browsers-mcp.env`.

Useful checks:

```bash
curl -fsS http://127.0.0.1:8787/health
launchctl print gui/$UID/com.gabrielalonso.gabriel-browsers-mcp
```

O runtime fica em releases imutáveis sob `~/.codex/gabriel-browsers-mcp/releases` no macOS e `~/.local/share/gabriel-browsers-mcp/releases` no Linux. O runtime macOS permanece no disco interno para não depender da permissão de volumes removíveis do `launchd`. Rollback troca apenas o symlink `current`; profiles e browsers não são copiados nem reiniciados.

## Responsabilidade do app

O app pode solicitar ao supervisor que libere um worker ocioso ou encerre um browser controlado. Ele não possui fallback de `kill`, não procura processos pela porta, não remove `SingletonLock` e não chama `/json/new` diretamente.

O próprio gateway encerra workers após cinco minutos ociosos. O botão manual existe para liberar memória imediatamente.

## Close controlled browsers

O botão de fechar solicita `SIGTERM` ao supervisor apenas para o processo identificado simultaneamente pelo diretório do perfil e pela porta CDP. A ação é recusada se houver lease ou chamada ativa, se a porta pertencer a outro processo ou se a identidade estiver ambígua. O Google Chrome normal permanece fora desse controle.
