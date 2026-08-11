# Gabriel Browsers Supervisor

Supervisor local dos perfis Chrome/Helium usados pelo Codex, pelo Custom CDP Browser e pelas CLIs das centrais.

```text
Codex MCP ───────┐
App macOS ───────┼──> gateway :8787 ──> supervisor por perfil ──> Chrome/Helium CDP
CLIs centrais ───┘          │
                            └──> worker Playwright lazy, no máximo um por perfil
```

O gateway pai fica leve e permanente. Um worker `@playwright/mcp` só nasce na primeira ferramenta Playwright de um perfil e é liberado após cinco minutos ocioso. Consultas de status, targets e leases não criam worker.

## Autoridade

- `src/profiles.json` é o manifesto canônico de IDs, aliases, browser, diretórios, portas e URLs padrão.
- Somente o supervisor inicia ou encerra perfis e valida locks.
- O app e as CLIs não apagam locks, não matam processos MCP e não lançam perfis diretamente.
- Leases `read` permitem leituras simultâneas; uma lease `write` é exclusiva por perfil.
- Abas abertas pela automação são registradas. A API só fecha targets registrados como pertencentes à automação.
- Perfil degradado, porta ocupada ou identidade ambígua falham de forma fechada.

## MCP

| Endpoint | Uso |
|---|---|
| `POST /mcp` | MCP único; as ferramentas recebem `profile`. |
| `POST /pessoal/mcp` | Alias do perfil pessoal. |
| `POST /central-es/mcp` | Alias da Central ES. |
| `POST /central-rj/mcp` | Alias da Central RJ. |
| `POST /financeiro-centralsp/mcp` | Alias do Financeiro/CentralSP. |

Ferramentas leves adicionais:

- `browser_profile_status`: estado do browser, worker e leases sem criar worker.
- `browser_targets`: lista targets sem Playwright.
- `browser_session`: adquire, renova ou libera uma lease para uma sequência de ações.
- `browser_target_open`, `browser_target_activate` e `browser_target_navigate`: operam por `target_id`, sem traduzir índices entre camadas.
- `browser_target_close`: fecha somente targets registrados como pertencentes à automação.

`browser_targets` e `browser_tabs` podem ordenar abas de forma diferente. Nunca passe um índice de uma ferramenta para a outra. Fechamento por índice no `browser_tabs` é bloqueado; `browser_tabs new` registra o target novo para fechamento posterior por ID.

Passe `session_id` às ferramentas Playwright durante uma sequência que precise de exclusividade. Sem sessão explícita, cada ferramenta recebe uma lease curta automaticamente.

## API de controle

| Endpoint | Uso |
|---|---|
| `GET /health` | Liveness do processo pai, sem token. |
| `GET /ready` | Readiness do supervisor. |
| `GET /v1/profiles` | Manifesto efetivo e estado de todos os perfis. |
| `GET /v1/profiles/:id/status` | Estado de browser, worker e leases. |
| `POST /v1/profiles/:id/start` | Garante que o perfil esteja pronto. |
| `POST /v1/profiles/:id/stop` | Encerra sem força e recusa leases/chamadas ativas. |
| `GET /v1/profiles/:id/targets` | Lista targets via CDP bruto. |
| `POST /v1/profiles/:id/open-url` | Abre target sob lease exclusiva curta. |
| `POST /v1/profiles/:id/targets/:targetId/activate` | Ativa um target pelo ID exato. |
| `POST /v1/profiles/:id/targets/:targetId/navigate` | Navega um target pelo ID exato. |
| `POST /v1/profiles/:id/worker/release` | Libera worker ocioso sem fechar o browser. |
| `POST/PATCH/DELETE /v1/leases` | Ciclo de vida das leases. |
| `GET /v1/profiles/:id/diagnostics` | Estado e targets para diagnóstico. |

Os endpoints legados `/workers` e `/release` permanecem apenas para compatibilidade.

## Resiliência do Playwright

O patch versionado em `patches/` corrige duas falhas do `@playwright/mcp 0.0.76`/`playwright-core`:

- frames raiz de páginas restauradas podem ter `targetId` diferente do frame principal; nesse caso a sessão principal é usada como fallback;
- `headerSnapshot()` limita `page.title()` a 500 ms e isola falhas por aba com `Promise.allSettled`.

Erros normais de locator ou aplicação não derrubam o worker. Timeout, transporte fechado ou browser desconectado substituem somente o worker do perfil afetado. Três substituições em 60 segundos abrem um circuit breaker de 30 segundos.

## Operação

```bash
npm install
npm run typecheck
npm test
npm run build
gabriel-browserctl health
gabriel-browserctl profiles
gabriel-browserctl status pessoal
gabriel-browserctl targets pessoal
gabriel-browserctl worker-release pessoal
```

## Instalação Por Release

O instalador executa `npm ci`, testes, typecheck e build em staging. Só depois publica uma release imutável e troca atomicamente o symlink `current`. O padrão é `~/.codex/gabriel-browsers-mcp` no macOS e `~/.local/share/gabriel-browsers-mcp` no Linux.

```bash
GABRIEL_BROWSERS_RELEASE_ID=0.2.1-parity scripts/install-runtime.sh
```

macOS:

```bash
scripts/install-launch-agent.sh
launchctl print gui/$UID/com.gabrielalonso.gabriel-browsers-mcp
```

Linux:

```bash
scripts/install-systemd-user-service.sh
systemctl --user --no-pager status gabriel-browsers-mcp.service
```

O token fica em `~/.codex/gabriel-browsers-mcp.env`. O LaunchAgent `com.gabrielalonso.gabriel-browsers-mcp` ou o serviço `gabriel-browsers-mcp.service` mantém somente o gateway pai ativo.

## Rollback

```bash
ls ~/.codex/gabriel-browsers-mcp/releases # macOS
ls ~/.local/share/gabriel-browsers-mcp/releases # Linux
CAMINHO_CURRENT/scripts/activate-release.sh NOME_DA_RELEASE_ANTERIOR
```

Depois reinicie apenas o gateway:

```bash
launchctl kickstart -k gui/$UID/com.gabrielalonso.gabriel-browsers-mcp
# ou
systemctl --user restart gabriel-browsers-mcp.service
```

A troca de release não encerra os browsers CDP. Antes de rollback/cutover, conferir leases com `gabriel-browserctl profiles`.

## Segurança

- bind e `Host` restritos a loopback;
- autenticação bearer em MCP e API de controle;
- CDP normalizado para `127.0.0.1`;
- remoção de lock limitada a symlinks comprovadamente obsoletos;
- `SIGKILL` somente com `force: true` explícito;
- nenhuma operação genérica por nome de processo.
