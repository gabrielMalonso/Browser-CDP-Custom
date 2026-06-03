# Custom CDP Browser

Small macOS launcher for Gabriel's persistent Helium CDP profiles.

## Profiles

| Name | Browser | Profile root | Profile directory | Port | Default URL |
|---|---|---|---|---:|---|
| Central ES | Helium | `~/.chrome-cdp/central-es` | `Default` | `9222` | WhatsApp Web |
| Central RJ | Helium | `~/.chrome-cdp/central-rj` | `Default` | `9223` | WhatsApp Web |
| Central SP | Helium | `~/.chrome-cdp/central-sp` | `Default` | `9225` | WhatsApp Web |
| Financeiro Rossoni | Google Chrome | `~/.chrome-cdp/financeiro-rossoni` | `Profile 12` | `9226` | Gmail inbox |
| Pessoal | Helium | `~/.chrome-cdp/pessoal` | `Default` | `9224` | none |

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
