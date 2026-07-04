# Custom CDP Browser

Small macOS launcher for Gabriel's persistent Chrome and Helium CDP profiles.

## Linux app

A nova implementação Linux fica isolada em `apps/linux`, usando Rust/Tauri/Svelte para perfis Chrome CDP e registro Ubuntu via `.desktop`/`xdg-mime`. Veja `apps/linux/README.md`.

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

When a selected profile is already running, links are opened through its DevTools `/json/new` endpoint. When it is closed, the browser is launched without an initial URL, waits for CDP to respond, then opens the incoming URL through `/json/new` instead of the profile's default URL.

## Gateway MCP/CDP

Codex talks to a lightweight local MCP gateway at `http://127.0.0.1:8787`. The gateway stays alive through the LaunchAgent `com.gabrielalonso.gabriel-browsers-mcp` and creates Playwright/CDP workers only when a tool is called.

| Path | Purpose |
|---|---|
| `/health` | Confirms the parent gateway is alive. |
| `/mcp` | Unified MCP server `gabriel-browsers`; tools receive a `profile` argument. |
| `/pessoal/mcp` | Compatibility alias for `playwright-cdp-pessoal`. |
| `/central-es/mcp` | Compatibility alias for `playwright-cdp-es`. |
| `/central-rj/mcp` | Compatibility alias for `playwright-cdp-rj`. |
| `/financeiro-centralsp/mcp` | Compatibility alias for `playwright-cdp-financeiro-centralsp`. |
| `/workers` | Protected worker status endpoint. |
| `/release` | Protected endpoint to release a worker without closing Helium. |

The gateway binds to `127.0.0.1`, validates loopback `Host`, and requires `Authorization: Bearer $GABRIEL_BROWSERS_MCP_TOKEN` for MCP/admin endpoints. The token lives in `~/.codex/gabriel-browsers-mcp.env`.

Useful checks:

```bash
curl -fsS http://127.0.0.1:8787/health
launchctl print gui/$UID/com.gabrielalonso.gabriel-browsers-mcp
```

Rollback is simple: restore the timestamped `~/.codex/config.toml` backup or uncomment the preserved stdio block in the config, then restart Codex.

## Release MCP workers

Profile rows show active Playwright MCP workers for that profile's CDP port. When the gateway is available, the release button calls `/release` and lets the gateway close the worker cleanly.

This does not close Helium or Chrome, does not kill generic `node` processes, and does not affect workers connected to other profile ports.

## Close controlled browsers

The footer close button terminates only browsers listening on the app's known CDP ports. It closes the controlled CDP profiles without targeting the normal Google Chrome app.

If the gateway is unavailable, the app falls back to the legacy direct process cleanup. That path is deliberately secondary because killing a Codex-owned stdio MCP process closes the transport that the current Codex thread is holding and can cause `Transport closed`.
