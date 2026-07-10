# Browser CDP Custom Linux

Implementação Linux do launcher/roteador de links CDP, isolada da app macOS. A janela principal funciona como overlay: escolha um perfil ou o Chrome normal e ela se oculta, mantendo uma única instância leve pronta para a próxima abertura ou link recebido.

## Experiência do overlay

- Abrir o app novamente apenas traz a instância existente para a frente; não cria overlays duplicados.
- Ao clicar em um navegador, o overlay se oculta automaticamente. Esse comportamento pode ser desligado em **Configurações**.
- Quando o app recebe um link e a regra é **Perguntar sempre**, o overlay mostra o domínio e deixa você escolher o destino.
- `Esc` oculta o overlay sem encerrar o processo. Use **Configurações → Encerrar app** para sair completamente.

## Configurações

O botão de engrenagem abre uma janela separada com:

| Opção | Comportamento |
|---|---|
| Ocultar após abrir | Fecha visualmente o overlay depois da seleção. |
| Iniciar com o Ubuntu | Cria uma entrada em `~/.config/autostart` e inicia oculto. |
| Perguntar sempre | Mostra o seletor a cada link externo. |
| Destino fixo | Envia links direto para um perfil CDP ou para o Chrome normal. |
| Último selecionado | Repete a última escolha; antes da primeira, usa o destino fixo. |
| Definir como padrão | Registra e seleciona o app para `http`, `https` e `text/html` via `xdg-mime`. |

As preferências ficam em `~/.config/browser-cdp-custom-linux/preferences.json`. URLs que falharem durante o roteamento continuam persistidas em `~/.local/share/browser-cdp-custom-linux/pending-links.json` para nova tentativa.

## Perfis

| Perfil | Caminho padrão | Porta | Status encontrado |
|---|---|---:|---|
| Central ES | `~/.chrome-cdp/central-es` | `9222` | existe nesta máquina |
| Central SP | `~/.chrome-cdp/financeiro-centralsp` | `9226` | configurável; não foi encontrado diretório real durante a inspeção |
| Central RJ | `~/.chrome-cdp/central-rj` | `9223` | existe nesta máquina |

O app não apaga `SingletonLock`, `SingletonSocket`, cache ou qualquer arquivo de profile. Ele também não cria diretório de profile automaticamente. Se um profile estiver preso por lock real ou ausente, ele acusa o erro em vez de brincar de roleta-russa com seus dados.

Quando uma porta já está aberta, o app só reutiliza o CDP se encontrar um processo com `--remote-debugging-port` e `--user-data-dir` compatíveis com o perfil. Porta aberta sozinha não prova nada.

Para sobrescrever perfis:

```bash
mkdir -p ~/.config/browser-cdp-custom-linux
cp apps/linux/profiles.example.json ~/.config/browser-cdp-custom-linux/profiles.json
```

Também dá para apontar outro arquivo:

```bash
BROWSER_CDP_CUSTOM_CONFIG=/caminho/profiles.json npm run tauri dev
```

## Desenvolvimento

```bash
cd apps/linux
npm install
scripts/check.sh
npm run tauri dev
```

Para exigir a compilação Tauri dentro do check:

```bash
REQUIRE_TAURI=1 scripts/check.sh
```

## Build Tauri

Dependências nativas no Ubuntu:

```bash
sudo apt install pkg-config libdbus-1-dev libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev
```

```bash
cd apps/linux
npm install
npm run tauri build
```

Se o Ubuntu reclamar de WebKitGTK, instale as dependências do Tauri v2 para Linux e rode de novo.

## Browser padrão no Ubuntu

Depois do build, o caminho recomendado é abrir **Configurações → Definir como padrão**. O próprio app cria o `.desktop` apontando para o executável em uso e configura `xdg-mime`.

O script continua disponível para instalação por terminal:

```bash
apps/linux/scripts/install-default-browser.sh --yes
```

O bundle Tauri também declara `text/html`, `x-scheme-handler/http` e `x-scheme-handler/https` no `.desktop` gerado. O script acima continua útil porque escolhe explicitamente este app como padrão via `xdg-mime`.

Validação:

```bash
xdg-mime query default x-scheme-handler/http
xdg-mime query default x-scheme-handler/https
xdg-open 'https://example.com/?origem=teste'
```

O `.desktop` passa o link como `%u`. A instância única recebe o argumento e aplica a regra escolhida: perguntar, destino fixo ou último selecionado.

## Gateway MCP/CDP

O Linux usa a mesma arquitetura do macOS: o Codex fala com um gateway MCP leve em `http://127.0.0.1:8787`, e o gateway cria workers `@playwright/mcp` sob demanda para cada perfil.

| Path | Uso |
|---|---|
| `/health` | Confirma que o processo pai está vivo. |
| `/mcp` | MCP unificado `gabriel-browsers`, com argumento `profile`. |
| `/pessoal/mcp` | Alias compatível para `playwright-cdp-pessoal`. |
| `/central-es/mcp` | Alias compatível para `playwright-cdp-es`. |
| `/central-rj/mcp` | Alias compatível para `playwright-cdp-rj`. |
| `/financeiro-centralsp/mcp` | Alias compatível para `playwright-cdp-financeiro-centralsp`. |
| `/workers` | Status protegido dos workers. |
| `/release` | Libera worker sem fechar Chrome/CDP. |

Instalação do gateway:

```bash
cd gateway/gabriel-browsers-mcp
npm install
npm run cache-tools
npm run build
npm run install-service
```

Validação:

```bash
curl -fsS http://127.0.0.1:8787/health
systemctl --user status gabriel-browsers-mcp.service
```

Se o gateway precisar abrir Chrome, o `systemd --user` precisa herdar a sessão gráfica:

```bash
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
```

Não habilite `linger` para este serviço por padrão. Ele foi feito para viver junto da sessão gráfica.

## QA manual

1. Rode `cargo test --manifest-path apps/linux/crates/cdp-core/Cargo.toml`.
2. Rode `cd apps/linux && npm run check && npm run build`.
3. Abra `npm run tauri dev` e confirme que ES/RJ aparecem, SP aparece como configurável.
4. Clique em ES, confirme que o overlay some e valide `curl -fsS http://127.0.0.1:9222/json/version`.
5. Use **Abrir URL** com uma URL contendo `?a=1&b=https://x.test/` e confirme que abre em nova aba.
6. Faça o build Tauri, registre com `install-default-browser.sh --yes`, e teste `xdg-open`.
7. Configure **Perguntar sempre**, abra dois links com `xdg-open` e confirme que ambos chegam à mesma instância do overlay.
8. Teste porta ocupada com algo que não seja CDP e confirme que a app coloca o link na fila em vez de perder a URL.
