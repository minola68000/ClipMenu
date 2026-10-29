ClipMenu (maintenance fork)
===========================

A clipboard manager for macOS.

**This is an unofficial maintenance fork** of [naotaka/ClipMenu](https://github.com/naotaka/ClipMenu). It modernizes the classic Objective-C app for current macOS (including Apple Silicon) and is **not** affiliated with the original author.

Upstream announced a separate, Swift-based ClipMenu under development; that work is unrelated to this fork.

![ClipMenu](./screenshot.jpg)

## Distribution

The original author’s distribution request still applies:

1. **Don’t use “ClipMenu” as your product name** if you distribute a *derived product* (especially via the Mac App Store or as a separately branded app).
2. **Follow the MIT license terms** (see `LICENSE`).

**How this fork interprets that for GitHub:**

- Keeping the name **ClipMenu** and Bundle ID `com.naotaka.ClipMenu` here is intentional so existing user data and preferences continue to work when replacing the original app locally.
- If you redistribute a *renamed / rebranded* derivative (store listing, commercial product, etc.), change the product name (and typically the Bundle ID) and keep MIT attribution.

## What’s different in this fork

- Universal binary (`arm64` + `x86_64`), deployment target macOS 12+
- Sparkle 2, Shortcut Recorder 3, and updated AppKit usage
- Automatic update checks against the original Feedburner appcast are **disabled** (no fork appcast is published)
- Build helpers: `script/build-modern.sh`, `script/install-modern.sh`

Version string: **0.4.5** (maintenance port of upstream `0.4.4a13`).

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

## Dependencies

Bundled / vendored (see `THIRD_PARTY_NOTICES.md` for license details):

- [PTHotKey](https://github.com/sdegutis/DDHotKey) lineage — Quentin D. Carnicelli (sources under `Source/PTHotKeys/`)
- [Shortcut Recorder](https://github.com/Kentzo/ShortcutRecorder) 3.x
- [Sparkle](https://sparkle-project.org/) 2.x
- [DBPrefsWindowController](https://github.com/davedelong/DBPrefsWindowController) — Dave Batton (`Source/DBPrefsWindowController/`)
- [BWToolkit](https://github.com/bwalkin/BWToolkit) — Brandon Walkin (framework still linked; Snippet Editor UI ported off BW-specific IB classes where needed)

## Author / attribution

- Original author: Naotaka Morimoto ([@naotakaM](https://twitter.com/naotakaM)) — [upstream repository](https://github.com/naotaka/ClipMenu)
- This fork: maintenance contributors (macOS modernization)

## License

ClipMenu is available under the MIT license. See the `LICENSE` file for more info.

Icons are copyrighted by their respective authors.
