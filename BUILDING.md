# Building and testing FocusPilot

Requires macOS 26 and Xcode 27 (selected with `xcode-select`). No Apple Developer membership is needed.

## Run the tests

```sh
swift test
```

Tests use Swift Testing and cover `FocusPilotCore`, so they need no app host or signing.

## Build and run the app

```sh
./scripts/build-app.sh
open build/FocusPilot.app
```

The script builds a release executable, wraps it in `build/FocusPilot.app` with `Packaging/Info.plist`, compiles the app icon with `actool`, and signs it ad hoc. The bundle runs only on the Mac that built it.

Before turning on "Open at Login", copy the app somewhere stable and launch that copy:

```sh
ditto build/FocusPilot.app ~/Applications/FocusPilot.app   # or /Applications
open ~/Applications/FocusPilot.app
```

The login item points at one specific app on disk. Every ad hoc rebuild changes the signature, and a worktree's `build/` folder goes away when the worktree is removed, so a login item registered from `build/` can stop working.

Prefer the bundle over `swift run FocusPilot`: the bare executable has no Info.plist, so `LSUIElement` and login-item registration do not apply to it.

## The focuspilot command

`build-app.sh` also builds the `focuspilot` command and puts it in `FocusPilot.app/Contents/Helpers/focuspilot`. See [docs/FOCUSPILOT_CLI.md](docs/FOCUSPILOT_CLI.md) for what it does and how to put it on your PATH.

To try the app and the command without touching your data, start both with `FOCUSPILOT_DATA_DIR` set to a short temporary folder:

```sh
export FOCUSPILOT_DATA_DIR=/tmp/fp-try
build/FocusPilot.app/Contents/MacOS/FocusPilot &
build/FocusPilot.app/Contents/Helpers/focuspilot add "Try the command by tomorrow"
```

Note that this runs under the same bundle ID as an installed FocusPilot, so it shares its settings (for example the first-launch flag). Quit the installed copy first.

With `FOCUSPILOT_DATA_DIR` set, the app does not touch your Chrome's host registration. It registers its host in `$FOCUSPILOT_DATA_DIR/Chrome User Data/NativeMessagingHosts`, which a Chrome started with `--user-data-dir="$FOCUSPILOT_DATA_DIR/Chrome User Data"` reads. That separate Chrome keeps your own Chrome and its FocusPilot connection as they are.

## Artwork

The app icon and the menu bar glyphs are drawn from the logo geometry in code (`Sources/FocusPilotCore/AppIcon` and `Sources/FocusPilotCore/MenuBar`); they have no hand-drawn image files. `build-app.sh` writes `build/artwork/AppIcon.icon` (an Icon Composer file) and compiles it into the bundle.

To review the artwork without launching the app:

```sh
./scripts/render-review-images.sh /tmp/focuspilot-artwork
```

This writes the four menu bar glyphs in light and dark (with and without the time label) and the app icon at 1024, 128, 32 and 16 px, rendered by Icon Composer's `ictool`.

### Raccoon companion art

The raccoon's poses come from the owner's pose sheet, `Artwork/Raccoon/raccoon-sheet.png` (20 poses, decision 0004). `Artwork/Raccoon/poses.json` holds what the sheet does not: each pose's name and caption, the walking pose's leg pivots, and the motion from the approved mockup (head tilt, breathing, blinking, leg swing, effect timings).

The generator cuts every pose into a horizontal strip of 256 × 256 layers (body, head, closed-eyes head, still objects, floating effects, floor shadow, and four legs for Walking) and writes `Packaging/Raccoon/<pose>.png` plus `Packaging/Raccoon/raccoon.json` (layers present, head pivot, motion). The output is committed and `build-app.sh` copies it into `Contents/Resources/Raccoon`, so building the app does not run the generator. After changing the sheet, `poses.json` or the generator, rebuild and commit the output:

```sh
./scripts/build-raccoon-art.sh /tmp/raccoon-contact-sheet.png
```

The optional path also renders a contact sheet: every pose at rest and, next to it, with the head tilted, eyes closed and legs swung, to check for seams. The generator is deterministic: on the same macOS version, the same inputs give byte-identical files. A different macOS version may encode the PNGs differently (ImageIO), so the tests compare decoded pixels, not bytes. It is Swift (`Sources/RaccoonRig`, run through `RenderArtwork raccoon`), with no extra dependencies. `Package.swift` compiles `RaccoonRig` with `-O` even in debug builds (an `unsafeFlags` setting): unoptimized, its pixel loops made `swift test` slow enough to starve the timing-sensitive tests. `RaccoonArtTests` fail if the committed output is out of date, if the layers at rest differ from the sheet beyond removed specks, or if a still object or the shadow ends up in a moving layer.

## Layout

| Path | Contents |
|---|---|
| `Sources/FocusPilotCore` | Testable logic: storage, coordinator, tasks and deadlines, login item, menu bar state, artwork geometry |
| `Sources/FocusPilot` | The SwiftUI app: menu bar item, planning window, settings |
| `Sources/FocusPilotCLI` | The `focuspilot` command; all its logic is `FocusPilotCommand` in core |
| `Sources/RenderArtwork` | Build-time tool that writes `AppIcon.icon`, review images and the raccoon art |
| `Sources/RaccoonRig` | Developer-only code that cuts the raccoon sheet into layers; not linked into the app |
| `Artwork/Raccoon` | Raccoon pose sheet and pose descriptions (generator input) |
| `Packaging/Raccoon` | Generated raccoon layer strips and `raccoon.json`, bundled by `build-app.sh` |
| `Tests/FocusPilotCoreTests` | Swift Testing suites for `FocusPilotCore` |
| `Packaging/Info.plist` | Bundle metadata, including `LSUIElement` |

## Data

The app stores two SQLite files in `~/Library/Application Support/FocusPilot`:

- `FocusPilot.sqlite`: owner data (tasks and, later, deadlines, preferences and focus rules).
- `CommandLine/`: the `focuspilot` command's socket and its inbox of tasks queued while the app was closed. Owner-only.
- `Cache.sqlite` (with `Cache.sqlite-wal` and `Cache.sqlite-shm`): derived values. To clear it by hand, quit the app and delete all three files; it is recreated empty on launch. If the cache cannot be opened, the app deletes and recreates it on its own; owner data is never affected.
