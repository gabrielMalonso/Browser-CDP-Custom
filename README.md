# Custom CDP Browser

Small macOS launcher for Gabriel's persistent Helium CDP profiles.

## Profiles

| Name | Browser | Profile root | Profile directory | Port | Default URL |
|---|---|---|---|---:|---|
| Pessoal | Helium | `~/.chrome-cdp/pessoal` | `Default` | `9224` | none |
| Central ES | Helium | `~/.chrome-cdp/central-es` | `Default` | `9222` | WhatsApp Web |
| Central RJ | Helium | `~/.chrome-cdp/central-rj` | `Default` | `9223` | WhatsApp Web |
| Central SP | Helium | `~/.chrome-cdp/central-sp` | `Default` | `9225` | WhatsApp Web |
| Financeiro Rossoni | Google Chrome | `~/.chrome-cdp/financeiro-rossoni` | `Profile 12` | `9226` | Gmail inbox |

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

When a selected profile is already running, links are opened through its DevTools `/json/new` endpoint. When it is closed, the browser is launched with the incoming URL as the initial page instead of the profile's default URL.
