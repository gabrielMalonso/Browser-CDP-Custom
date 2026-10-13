# Browser CDP Custom Linux

App Tauri/Svelte para os mesmos perfis e o mesmo supervisor usados pelo app macOS, pelo Codex e pelas CLIs.

## Autoridade

O app Linux não inicia ou encerra Chrome diretamente, não inspeciona processos, não remove `Singleton*` e não chama CDP bruto. Todas as ações passam pela control API v1 autenticada em `http://127.0.0.1:8787`.

| Ação do app | API do supervisor |
|---|---|
| listar estados | `GET /v1/profiles` |
| abrir perfil | `POST /v1/profiles/:id/start` ou `open-url` |
| rotear link | `POST /v1/profiles/:id/open-url` |
| fechar perfil | `POST /v1/profiles/:id/stop` |
| liberar worker | `POST /v1/profiles/:id/worker/release` |

O app exige `controlApi: 1`, `leases: true` e `browserLifecycle: true`. Uma versão antiga do gateway falha fechado.

## Perfis

| ID canônico | Caminho Linux | Porta |
|---|---|---:|
| `pessoal` | `~/.chrome-cdp/pessoal` | `9224` |
| `central-es` | `~/.chrome-cdp/central-es` | `9222` |
| `central-rj` | `~/.chrome-cdp/central-rj` | `9223` |
| `financeiro-centralsp` | `~/.chrome-cdp/financeiro-centralsp` | `9226` |

O arquivo local opcional `~/.config/browser-cdp-custom-linux/profiles.json` guarda apenas apresentação e roteamento padrão. Lifecycle e identidade efetiva vêm do manifesto do supervisor. Veja `profiles.example.json`.

## Desenvolvimento

```bash
cd apps/linux
npm ci
scripts/check.sh
```

Para exigir a compilação Tauri completa:

```bash
sudo apt install pkg-config libdbus-1-dev libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev
REQUIRE_TAURI=1 scripts/check.sh
npm run tauri build
```

## Browser Padrão

Depois do build:

```bash
apps/linux/scripts/install-default-browser.sh --yes
xdg-mime query default x-scheme-handler/http
xdg-mime query default x-scheme-handler/https
```

Links recebidos ficam em fila local se o supervisor recusar ou estiver indisponível. O retry volta a usar a mesma API; nunca contorna por CDP direto.

## Pré-requisito

Instale primeiro o runtime e o serviço conforme `gateway/gabriel-browsers-mcp/README.md`. Validação mínima:

```bash
gabriel-browserctl health
gabriel-browserctl profiles
systemctl --user --no-pager status gabriel-browsers-mcp.service
```

Não habilite `linger` por padrão. O supervisor Linux foi desenhado para viver com a sessão gráfica do usuário.
