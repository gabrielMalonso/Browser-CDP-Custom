# Custom CDP Browser

Small macOS launcher for Gabriel's persistent Helium CDP profiles.

## Profiles

| Name | Browser | Profile root | Profile directory | Port | Default URL |
|---|---|---|---|---:|---|
| Pessoal | Helium | `~/.chrome-cdp/pessoal` | `Default` | `9224` | none |
| Central ES | Helium | `~/.chrome-cdp/central-es` | `Default` | `9222` | WhatsApp Web |
| Central RJ | Helium | `~/.chrome-cdp/central-rj` | `Default` | `9223` | WhatsApp Web |
| Financeiro/CentralSP | Helium | `~/.chrome-cdp/financeiro-centralsp-helium` | `Profile 1` | `9226` | WhatsApp Web |

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

## Disconnect MCP clients

Profile rows show active Playwright MCP clients for that profile's CDP port. The disconnect button only targets processes with a command line matching `playwright-mcp --cdp-endpoint http://127.0.0.1:<port>` or the equivalent `localhost` endpoint.

This does not close Helium or Chrome, does not kill generic `node` processes, and does not affect MCP clients connected to other profile ports.
