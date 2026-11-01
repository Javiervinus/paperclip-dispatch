# Images

Images used by `README.md`, `README.es.md` and the landing (`site/build.sh` makes its WebP versions from
them). The landing's hero notifications are HTML and CSS drawn with the measurements of `notification.png`
(`site/styles.css`, `.strip`), so check them if that capture's layout changes. They are taken with
`macos/snapshot.zsh` from a test copy of the app (another `APP_ID`, in English with `APP_LANGUAGE=en`)
connected to a separate Paperclip instance with a made-up company. No personal information is on screen (company names, tasks, addresses).

| File | What it shows | How |
| --- | --- | --- |
| `icon.png` | The app icon, 256 × 256 pt, with its rounded shape | Exported from `macos/AppIcon.icon` with Icon Composer's `ictool` (`--width 256 --height 256 --scale 2`) |
| `window-light.png` | The main window on the Paperclip dashboard, light | `SHADOW=0 SIZE=1280x800 macos/snapshot.zsh page /<PREFIX>/dashboard`, with Appearance set to Light in the copy's Settings |
| `window-dark.png` | The same, dark | The same, with Appearance set to Dark |
| `window-glass.png` | The main window with the Liquid Glass sidebar | The same, light, with Liquid Glass in Paperclip turned on |
| `welcome.png` | The connection step of the welcome | `macos/snapshot.zsh welcome` (`found-light.png`) |
| `settings.png` | Settings, General tab | `macos/snapshot.zsh settings` (`general-light.png`) |
| `notification.png` | The stuck-task notification with its Wake up button, light | `macos/snapshot.zsh notifications` (`mac-agent-light.png`) |
| `notification-dark.png` | The same, dark (used by the landing in dark mode) | `macos/snapshot.zsh notifications` (`mac-agent-dark.png`) |

There is no dark version of `window-glass.png` yet: the sample Paperclip instance it was taken from no
longer exists, and a new one would not match the light capture. The landing uses the light one in both themes.

The landing's share image (`og:image`, 1200 × 630) is composed from these captures by
`site/social/card.html` and saved as `site/social/card.jpg`; that page explains how to remake it. Remake it
when `icon.png`, `window-light.png` or `notification.png` change.

The window images use `page` instead of `window` because `page` follows the copy's own Appearance and Liquid
Glass settings, so light and dark don't depend on the Mac's.

Keep them as PNG, at 2× and under 1 MB each.
