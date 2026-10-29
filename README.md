ClipMenuNeo (maintenance fork of ClipMenu)
====================================

A clipboard manager for macOS.

**This is an unofficial maintenance fork** of [naotaka/ClipMenu](https://github.com/naotaka/ClipMenu). It modernizes the classic Objective-C app for current macOS (including Apple Silicon) and is **not** affiliated with the original author.

Upstream announced a separate, Swift-based ClipMenu under development; that work is unrelated to this fork.

![ClipMenuNeo](./screenshot.jpg)

## Distribution

The original author’s distribution request still applies:

1. **Don’t use “ClipMenu” as your product name** if you distribute a *derived product* (especially via the Mac App Store or as a separately branded app).
2. **Follow the MIT license terms** (see `LICENSE`).

**How this fork handles that:**

- The product is named **ClipMenuNeo** and uses its own Bundle ID `io.github.minola68000.ClipMenuNeo` (same approach as CleanArchiverNeo). The app bundle file is still `ClipMenu.app`.
- Preferences and history of the original `com.naotaka.ClipMenu` are **not** carried over, and macOS permissions (Accessibility / Input Monitoring) must be granted again.
- If you redistribute a further derivative (store listing, commercial product, etc.), change the product name and Bundle ID and keep MIT attribution.

## What’s different in this fork

- Universal binary (`arm64` + `x86_64`), deployment target macOS 12+
- Sparkle 2, Shortcut Recorder 3, and updated AppKit usage
- Incremental search in the menu: typing fills the search field at the top; the filter applies after 0.5 s without input. Matches are re-packed from the top into inline items and folders, with the matched text highlighted in yellow. Snippets and Preferences / Quit stay available while filtering. Digit keys no longer jump to items, and history numbers are not shown.
- Automatic update checks against the original Feedburner appcast are **disabled** (no fork appcast is published)
- Build helpers: `script/build-modern.sh`, `script/install-modern.sh`

Version string: **0.4.5** (maintenance port of upstream `0.4.4a13`). Set via `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the Xcode project; the copyright line lives in `InfoPlist.strings`. Later fork releases append a digit (e.g. `0.4.51`), as CleanArchiverNeo does (`4.0` → `4.01`).

## Permissions

Incremental search captures keys while the menu is open, which needs **Accessibility** and **Input Monitoring** (System Settings → Privacy & Security). macOS asks once per launch. Grants are tied to the code signature, so sign with a stable identity — ad-hoc re-signing resets them.

## Target environments

- macOS 12 or later (built and tested on current macOS)
- Xcode with a recent macOS SDK
- Manual reference counting (MRC), Objective-C

Legacy upstream targets (OS X 10.5–10.6 / Xcode 3.2) are no longer the focus of this fork.

## Build

Frameworks expected under `Frameworks/` (Sparkle, ShortcutRecorder, BWToolkitFramework) are included in this repository for convenience.

```sh
./script/build-modern.sh
# optional: build and replace /Applications/ClipMenu.app
./script/install-modern.sh
```

Override architectures with `CLIPMENU_ARCHS` (default: `arm64 x86_64`).

`install-modern.sh` re-signs the app with the first Apple Development identity in your keychain (override with `CLIPMENU_SIGN_IDENTITY`). `script/e2e-filter.sh` runs the in-process filter self-test. Set `CLIPMENU_FILTER_LOG=/path/to/file` to write a debug log of the filter (it records typed text, so it is off by default).

## Dependencies

Bundled / vendored (see `THIRD_PARTY_NOTICES.md` for license details):

- [PTHotKey](https://github.com/sdegutis/DDHotKey) lineage — Quentin D. Carnicelli (sources under `Source/PTHotKeys/`)
- [Shortcut Recorder](https://github.com/Kentzo/ShortcutRecorder) 3.x
- [Sparkle](https://sparkle-project.org/) 2.x
- [DBPrefsWindowController](https://github.com/davedelong/DBPrefsWindowController) — Dave Batton (`Source/DBPrefsWindowController/`)
- [BWToolkit](https://github.com/bwalkin/BWToolkit) — Brandon Walkin (framework still linked; Snippet Editor UI ported off BW-specific IB classes where needed)

## Author / attribution

- Original author: Naotaka Morimoto ([@naotakaM](https://twitter.com/naotakaM)) — [upstream repository](https://github.com/naotaka/ClipMenu)
- This fork: ClipMenuNeo contributors (macOS modernization, incremental search)

## License

ClipMenu is available under the MIT license. See the `LICENSE` file for more info.

Icons are copyrighted by their respective authors.
