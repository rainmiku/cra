<p align="center">
  <img src="brand/cra-segments-icon.svg" alt="Cra logo" width="128" height="128">
</p>

# Cra

A native macOS browser built on Chromium (CEF), shaped after the parts of Arc
worth keeping: a sidebar instead of a tab strip, spaces, pinned tabs with a
home URL, favorites shared across spaces, a command bar for new tabs that
searches open and archived tabs, auto-archiving, folders, and Chrome DevTools.

Shell: Swift (AppKit + SwiftUI). Engine: Chromium Embedded Framework.

## Install

Needs macOS 14 or later on Apple silicon.

**Easiest: paste this into Terminal** (Applications → Utilities → Terminal)

    curl -fsSL https://raw.githubusercontent.com/VictorKildahl/cra/main/scripts/install.sh | bash

It puts Cra in your Applications folder and opens it, with no security prompts. Run
the same line again any time to update.

**Or download [Cra.dmg](https://github.com/VictorKildahl/cra/releases/latest/download/Cra.dmg)**

1. Open `Cra.dmg` and drag Cra to Applications.
2. Open Cra. macOS says it could not verify the app. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**
   next to "Cra was blocked".
4. Confirm with Touch ID or your password, then click **Open Anyway** once more.

You only do this once. Cra is not notarized by Apple yet; every line of it is in this
repository.

## Build

    scripts/build.sh          # fetches CEF on first run, builds build/Cra.app
    scripts/run.sh            # build if needed, then open
    scripts/dev.sh            # dev loop: debug CraDev.app, rebuilds + relaunches on save (~4 s)

Requirements: Xcode 16+, CMake (`brew install cmake`).

## Release

`scripts/release.sh` builds, signs with a Developer ID, notarizes, and packages a DMG and
zip into `build/dist`. Pushing a `v*` tag runs the same through GitHub Actions and
publishes a release. See `docs/release.md` for the one-time certificate setup.

## Layout

- `Sources/Cra` — the app (model, store, sidebar, command bar, windows)
- `Sources/CraCEF` — Objective-C++ bridge to CEF
- `Sources/CraHelper` — Chromium subprocess executable
- `docs/arc-reverse-engineering.md` — what was learned from Arc and how
- `vendor/cef` — CEF binary distribution (not committed)

Data lives in `~/Library/Application Support/io.github.rainmiku.cra`.

## Scripting hooks

Cra registers the `cra://` scheme. Any app can send it, so it only takes harmless
commands (web pages can't send it at all):

    open "cra://commandbar?query=github"    # open the command bar with text
    open "cra://open?url=https://example.com&background=1"   # http(s) only
    open "cra://dismiss"                    # close sheets, command bar, find bar

Everything else (`action/<id>` with any action id from KeyBindings.swift, `key`,
`import`, `debug`, `navigate`, and `open` with other URLs) is a testing hook: start Cra
with `CRA_COMMAND_FILE` set and append cra:// lines to that file
(`scripts/smoke-test.sh` does this):

    open -a Cra --env CRA_COMMAND_FILE=/tmp/cra-commands   # Cra not already running
    echo "cra://action/newTab" >> /tmp/cra-commands

## Little Windows (Arc's Little Arc)

Links from other apps open in a Little Window: a small, sidebar-less window with one
search pill and an "Open in <Space> ⌘O" button. The page is not in the sidebar; closing
the window (⌘W) archives it to the Library, ⌘O (or the chevron menu) moves it into a space
as a Today tab, keeping the live page. ⌥⌘N opens an empty one. Settings → Tabs turns the
link routing off; `open "cra://open?url=https://…&little=1"` opens one from a shell.

## Import

Cra menu → Import from Arc or Dia…, or Settings → Import. Imports from Arc, Dia,
Chrome, Brave, Edge, Opera, Opera GX, Vivaldi, Chromium, Firefox, Zen and Safari: Arc's
StorableSidebar.json / StorableArchiveItems.json, Dia's profile containers, and
bookmarks, history, extensions, passwords and cookies from the other browsers.
Spaces with the same name merge; tabs already present are skipped.
Headless: `cra://import?source=arc&archive=1&settings=1` through `CRA_COMMAND_FILE`.

## Keyboard

Arc's defaults: ⌘T new tab · ⌘L command bar / edit URL · ⌘W close tab (window
when no tab) · ⇧⌘W close window · ⇧⌘T restore closed tab · ⌘S sidebar ·
⇧⌘D toolbar · ⌘D pin/unpin · ⇧⌘C copy URL · ⇧⌥⌘C copy as Markdown ·
⌘1…9 go to tab · ⌃1…9 go to space · ⌥⌘←/→ spaces · ⌥⌘↑/↓ tabs · ⌃Tab recent
tab · ⇧⌘K clear Today · ⌘[ / ⌘] back/forward · ⌘Y history · ⇧⌘L library ·
⇧⌘J downloads · ⌥⌘I DevTools · ⌥⌘J console · ⌥⌘U source · ⌘F find.
Like Chrome, pages get first chance at unreserved shortcuts (⌘F in Docs works).
Every shortcut can be changed in Settings → Shortcuts; overrides are saved to
`~/Library/Application Support/io.github.rainmiku.cra/keybindings.json`.

## Rendering calibration hook

`cra://debug?lift=0&liftInactive=0.75&alpha=1&material=13&state=follows&appearance=dark`
through `CRA_COMMAND_FILE` changes the vibrancy parameters live (`CRA_TUNING` sets them at
launch; see `Sources/Cra/UI/Tuning.swift`). `material` is the
raw `NSVisualEffectView.Material` value, `alpha` scales the gradient opacity.

## DevTools

⌥⌘I toggles Chrome DevTools docked on the right of the page (drag the divider to resize);
Inspect Element from the context menu opens it at the clicked node. Each tab keeps its own
DevTools; the dock follows the selected tab.

## Brand

`brand/` holds the marks; `resources/brand/*.png` are WebKit renders of them (so the
multiply blends survive) used by `BrandMark`, and `resources/AppIcon.icns` is built from
`brand/cra-segments-icon.svg` (render at 1024 px, `iconutil`).

## Website and brand

The marketing site lives in a separate private repository (VictorKildahl/cra-website).
Logo sources are in `brand/` (see `brand/README.md`); `resources/brand` holds the PNGs the
app loads and `resources/AppIcon.icns` the app icon.

## Developer Mode and shortcuts

⌃D toggles Arc's per-site Developer Mode: the toolbar switches from the friendly centred
URL (nav buttons at its left) to the full monospace URL with the developer icons, and the
nav buttons move into the sidebar. Every shortcut can be changed in Settings → Shortcuts
(click the shortcut, press new keys; Esc cancels, ⌫ removes; conflicts are flagged).
Overrides live in `keybindings.json` in the app's support folder.

## Picture in Picture

View ▸ Picture in Picture (or "pip" in the command bar, or the context menu on a video) pops the
page's video out into Arc's floating window: bare 16:9, 6 pt corners, top-right, draggable and
resizable from its edges. Hovering it shows close, back to tab, play/pause and ±15 s buttons. Leaving a tab whose video is playing pops it
out automatically (Settings ▸ Tabs, "Enable Picture in Picture when you leave a video tab"), and
coming back to the tab brings the video home. `cra://action/pictureInPicture` (through `CRA_COMMAND_FILE`) toggles it.
