# Third-party notices

This maintenance fork redistributes or vendors the following components.
Full license texts for binary frameworks are also inside each framework’s
`Resources` (where provided by upstream).

## Sparkle 2.10.1

- Project: https://sparkle-project.org/
- Source: https://github.com/sparkle-project/Sparkle
- License: MIT (see Sparkle project `LICENSE`)
- Location: `Frameworks/Sparkle.framework`

## Shortcut Recorder 3.4.0

- Project: https://github.com/Kentzo/ShortcutRecorder
- License: Creative Commons Attribution 4.0 International (as shipped in the framework `Resources/LICENSE.txt`)
- Location: `Frameworks/ShortcutRecorder.framework`

## BWToolkitFramework

- Author: Brandon Walkin
- License: BSD-style (see `Frameworks/BWToolkitFramework.framework/.../Resources/License.rtf`)
- Location: `Frameworks/BWToolkitFramework.framework`

## PTHotKey

- Author: Quentin D. Carnicelli
- Location: `Source/PTHotKeys/`
- Copyright notices appear in the source headers.

## DBPrefsWindowController

- Author: Dave Batton
- Location: `Source/DBPrefsWindowController/`
- Copyright notices appear in the source headers.

## Notes

- Automatic Sparkle update feeds from the original ClipMenu distribution are
  disabled in this fork (`Info.plist` has no `SUFeedURL`).
- Appcast / release-note helper scripts under `script/` no longer embed
  machine-specific paths; set `CLIPMENU_PUBLIC_URL` and related environment
  variables if you publish your own feed.
