# AGENTS.md

Paperclip Dispatch is a native macOS app that shows the [Paperclip](https://paperclip.ing) web UI in its own
window and adds Mac notifications, a Telegram bot and updates (Sparkle). It is a Swift package built with
`swift build`: there is no Xcode project. `README.md` has the full picture.

## Where things are

- `macos/Sources/PaperclipDispatch/`: the app, one target. Its String Catalogs are `Localizable.xcstrings`
  and `InfoPlist.xcstrings` (permission texts).
- `macos/web/`: the JS and CSS injected into the Paperclip page (`WebResources.swift` lists them, in order).
- `macos/build.sh` builds the `.app`, `macos/snapshot.zsh` captures its windows and `macos/strings.zsh` syncs
  and checks the catalog. Each script documents its variables at the top.
- `.github/workflows/build.yml` is the CI. `CHANGELOG.md` and `CHANGELOG.es.md` are the release notes.

## Commands (from the repo root)

Build a test copy that runs alongside the installed app: pick any name and bundle id of your own (it gets its
own settings, session and keychain item). No update feed, so it never replaces itself with the published one:

    APP_NAME="Dispatch Dev" APP_ID=com.example.paperclip-dispatch.dev UPDATE_FEED_URL= \
      OUTPUT_DIR=~/Applications macos/build.sh

Never run `macos/build.sh` bare to try a change: without `OUTPUT_DIR` it installs in `/Applications` and
quits and replaces the app with the same name.

Capture windows without touching the screen, in both languages (`settings`, `window`, `welcome`, `about`,
`notifications`; it prints the folder). Always pass `APP_PATH`, or it opens the installed app. The terminal
needs the Screen Recording permission.

    APP_PATH="$HOME/Applications/Dispatch Dev.app" APP_LANGUAGE=en macos/snapshot.zsh settings
    APP_PATH="$HOME/Applications/Dispatch Dev.app" APP_LANGUAGE=es macos/snapshot.zsh settings

What the CI runs; run it before proposing a change:

    swift package --package-path macos --disable-keychain --force-resolved-versions resolve
    UNIVERSAL=1 SIGN_IDENTITY=- OUTPUT_DIR="$(mktemp -d)" macos/build.sh
    macos/strings.zsh --check

## Don't touch

- `macos/release.sh`, `macos/update-cask.sh` and publishing (tags, GitHub releases, the Homebrew tap).
- The Sparkle keys: `UPDATE_PUBLIC_KEY` and `SPARKLE_KEY_ACCOUNT` in `macos/release.env`, and the private
  key in the keychain.
- `macos/build.local.env`: one Mac's own settings, ignored by git. Don't read or commit it.

## Conventions

- Swift 6 (tools 6.2) and macOS 26 only; building needs Xcode 26.
- Repo skills for SwiftUI are in `.agents/skills` (linked from `.claude/skills`), pinned in
  `skills-lock.json`. Refresh them with `npx skills experimental_install`.
- Code is in English. Every user-facing text (`Text("…")`, `Button("…")`, `String(localized: "…")`) goes
  to the catalog: run `macos/strings.zsh` (it compiles and adds new keys to `Localizable.xcstrings`), then
  give each new key its Spanish in `localizations.es.stringUnit`, with `"state" : "translated"` and the
  `value`. A `String` passed to `Text(variable)` is not translated: build it with `String(localized:)`.
  Permission texts are in `InfoPlist.xcstrings`, edited by hand. `macos/strings.zsh --check` must pass.

## Proposing a change

- Small, focused commits in Conventional Commits, in English (`fix(macos): …`, `feat(macos): …`).
- A user-facing change gets one line under `## Unreleased` in both `CHANGELOG.md` and `CHANGELOG.es.md`,
  starting with a bold sentence for the person using the app.
- If something on screen changes, attach `snapshot.zsh` captures of it, in English and Spanish.
