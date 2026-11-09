# macOS platform notes

Research done on 2026-10-31 against the macOS 27.0 SDK (Xcode 27.0) on macOS 27.0.1. Items marked
**unverified** still need a test on a real device.

## Floating panel over every Space

- Use an `NSPanel` subclass created in code, hosting SwiftUI. SwiftUI scenes only offer
  `.windowLevel` and `.windowStyle(.plain)`; they cannot make a non-activating panel.
- Style mask `[.borderless, .nonactivatingPanel]` **at init**. Toggling `.nonactivatingPanel`
  later desynchronises the window server and breaks typing (FB16484811).
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]`.
  Combining `.canJoinAllSpaces` with `.moveToActiveSpace` raises an exception.
- An app with such a panel on screen has a window on every Space, so activating it does not take
  the reader to the Space where its other windows are. An ordinary window left on another Space
  comes forward there, out of sight; `.moveToActiveSpace` brings it to the reader's Space instead
  (checked 2026-11-03).
- macOS can leave such a panel on one Space while it keeps the rule (2026-11-07: the panel was on
  desktop 2 only, most likely since a full-screen Space closed while it was out and macOS went
  back to desktop 2). Ordering it front again, or setting the same `collectionBehavior` again,
  leaves it there; `isOnActiveSpace` does report it. Dropping `.canJoinAllSpaces` and inserting it
  again while the window shows puts it back on every Space, but only with the two changes some
  50 ms or more apart: the window server takes them a moment later, and in one turn of the run
  loop, or a few ms apart, they often cancel out (measured: next turn about half the time, 20 ms
  28 of 32, 50 and 100 ms 32 of 32). Checked in an app with the window server's own view
  (SkyLight `SLSCopySpacesForWindows`; `SLSRemoveWindowsFromSpaces` recreates the state, while
  `SLSMoveWindowsToManagedSpace` does not move a window that joins every Space). Not under
  `swift test`: there the rule's changes never move the window.
- Appearing over another app's full-screen Space needs the non-activating bit plus
  `.fullScreenAuxiliary` and no `.fullScreenPrimary` (Firefox PiP test, bug 1688932). A plain
  `NSWindow` never gets there. An accessory (`LSUIElement`) app satisfies this as well.
- `level = .floating` is enough to float over other apps, but the Dock (level 20) covers it. Nibble
  uses one level above the Dock so the panel can sit over it. The candidates (level 20) would then
  open under the panel; as its child windows they sit above it (see item 3 below). The input source
  badge showed one level above the panel on its own (checked 2026-11-01).
- `canBecomeKey = true` (borderless panels default to false), `canBecomeMain = false`. Show with
  `orderFrontRegardless()` + `makeKey()`. Never call `NSApp.activate()` for the panel: activation
  makes macOS leave the full-screen Space.
- A press on a non-key panel does give it the keyboard (2026-11-09), but AppKit hands that first
  press only to views whose `acceptsFirstMouse` is true. SwiftUI's selectable `Text` says no, so a
  drag over it selected nothing and ⌘C copied nothing; a second drag worked. `makeKey()` in the
  panel's `sendEvent` before `super` makes the press an ordinary one. Once the panel has the
  keyboard, `activate()` on the app in front does not take it back (that app is already active);
  a click in its window does. Checked on the real panel with HID mouse events (click count 1, a
  move first, a longer press — SwiftUI's selection ignores bare synthetic drags) and the
  system-wide `kAXFocusedApplicationAttribute`.
- `hidesOnDeactivate = false` explicitly.
- Stage Manager: `.canJoinAllApplications` (macOS 13) is documented for floating overlays.
  **Unverified** with Stage Manager on.
- ⌘C/⌘V/⌘A in an accessory app need an Edit menu in `NSApp.mainMenu`. **Unverified**: ⌘V while
  the panel is key and the app inactive.

Sources: searchfox.org/firefox-main/source/widget/tests/gtest/TestPiPWindowSpaceBehavior.mm ·
philz.blog/nspanel-nonactivating-style-mask-flag · github.com/p0deje/Maccy (FloatingPanel.swift) ·
github.com/japananh/aimonitor/pull/146 · developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications

## Dismiss on outside click only when empty

- `resignKey()` fires when the user clicks another app or the desktop. Hide there if the session
  is empty.
- It also fires for Nibble's own alerts, pickers and overlays: keep a "hold open" flag.
- Clicks that do not move key focus (menu bar, Dock) can be caught with
  `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown])`.
  Apple restricts only key events behind Accessibility; mouse monitors need no permission.
  **Unverified** on 27.

## Global hotkey

- Carbon `RegisterEventHotKey`: not deprecated in the 27 SDK, no permission, works sandboxed.
  ⌥-only combos were blocked in macOS 15.0–15.1 and allowed again from 15.2. Registration of
  ⌥Space returned `noErr` on 27.0.1 (**event delivery unverified**).
- Registration is not exclusive and cannot reveal another app holding the same combination.
  ⌥Space is also Alfred's default and ChatGPT Classic's companion-window shortcut; it normally
  types a non-breaking space. ⌃Space / ⌃⌥Space switch input sources; ⌘⌥Space opens Finder search.
- Package option: sindresorhus/KeyboardShortcuts 3.1.0 (Carbon-based, recorder UI, macOS 27
  fixes). Not used: Nibble draws its own recorder.
- Modifier-only gestures (double-tap ⌘): a listen-only `CGEventTap` on `flagsChanged`, which needs
  **Input Monitoring** (`CGPreflightListenEventAccess` / `CGRequestListenEventAccess`). Re-enable
  the tap on `tapDisabledByTimeout`. Double-⌥ collides with typing accented characters.
- TCC grants are bound to the code signature: sign Debug builds with a stable identity.

Sources: developer.apple.com/forums/thread/763878 · github.com/sindresorhus/KeyboardShortcuts ·
developer.apple.com/forums/thread/811443

## Screen capture

| API | Since | Note |
|---|---|---|
| `SCScreenshotManager.captureImage(contentFilter:configuration:)` | 14.0 | CGImage |
| `captureImage(in:)` | 15.2 | rect, cannot exclude windows |
| `captureScreenshot(contentFilter:configuration:)` | 26.0 | `SCScreenshotConfiguration`, SDR/HDR, heic/jpeg/png, file output |
| `captureScreenshot(rect:configuration:)` | 26.0 | same output, for a rect |

- Display under the panel without the panel: build `SCContentFilter(display:excludingApplications:[self])`
  with the `SCDisplay` matching `panel.screen?.cgDirectDisplayID`; no need to hide the panel.
  `sharingType = .none` is ignored by modern macOS.
- Window under the panel: `CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements], panelWindowNumber)`,
  first layer-0 window intersecting the panel, then `SCContentFilter(desktopIndependentWindow:)`.
- `CGWindowListCreateImage` is obsolete and returns grey images on 27.
- Permission: Screen & System Audio Recording (`CGPreflightScreenCaptureAccess` /
  `CGRequestScreenCaptureAccess`; the app must relaunch after granting). The periodic re-consent
  alert still exists on 27.0.1 and applies to screenshots (strings in ReplayKit and `replayd`).
  Frequency **unverified** (roughly monthly on 26).
- `SCContentSharingPicker` avoids the alert for content the user picks. Whether it needs no grant
  at all is **unverified**.
- Region selection like ⌘⇧4: `/usr/sbin/screencapture -i -x -o <file>` (no file means cancelled).
  It checks the calling app's Screen Recording grant. The alternative is an own overlay plus
  `captureScreenshot(rect:)`.

Sources: SDK headers SCScreenshotManager.h, SCShareableContent.h, SCContentSharingPicker.h ·
developer.apple.com/forums/thread/765103 · developer.apple.com/forums/thread/849969 ·
developer.apple.com/videos/play/wwdc2023/10136

## Pasting and dropping images

- SwiftUI `TextEditor` / `TextField` cannot take an image paste (`importsGraphics = false`, and the
  text view handles `paste:` itself). Use an `NSTextView` subclass in `NSViewRepresentable` that
  overrides `readablePasteboardTypes` and `readSelection(from:type:)`.
- Read file URLs first (`.urlReadingFileURLsOnly`), then png / jpeg / heic / webp / gif / tiff.
  Never fall back to TIFF when a file URL is present: a Finder copy carries the file **icon** as TIFF.
- Drops: the macOS 26 `dropDestination(for:isEnabled:action:)` with a custom `Transferable`
  (`FileRepresentation` then `DataRepresentation` for `.image`); read bytes inside the closure.
  The screenshot thumbnail is an `NSFilePromiseProvider` that also offers a file URL.
- macOS 27 terminates apps that call `receivePromisedFiles` outside the drag-operation callbacks.
- Pasteboard privacy: read the general pasteboard only inside a real paste action; never on panel
  open or on a timer.
- Downscale with ImageIO thumbnails (e.g. 1568 px long edge), PNG for screenshots, JPEG 0.85 for
  photos, convert P3 to sRGB. A 3456×2234 screenshot became 118 KB in 41 ms.

Sources: developer.apple.com/documentation/macos-release-notes/macos-27-release-notes ·
mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4

## Streaming Markdown

- SwiftUI `Text` renders inline Markdown only.
- LiYanan2004/MarkdownView 3.0.0: SwiftUI, `StreamingMarkdownSource` re-parses only the unfinished
  tail on a background task, throttle 50 ms. Selection per block; open leak issue #168.
- Lakr233/MarkdownView 4.8.x: AppKit/CoreText, built for streaming, own theme.
- Avoid for now: Textual 0.5 (re-parses on main, crashes with selection), MarkdownUI (maintenance
  mode).
- Rules: freeze finished blocks, re-parse the tail, throttle to 50–100 ms, highlight code blocks
  once closed.
- With a pixel-art style the renderer must accept custom fonts and colours; check before choosing.

## Distribution

- Menu-bar-only app (`LSUIElement`), status item always present (users can hide items since 26).
  Opening a normal window from an accessory app: switch to `.regular`, activate, switch back.
- Launch at login: `SMAppService.mainApp.register()`.
- No sandbox; hardened runtime; Developer ID signing and notarization.
- App Transport Security blocks plain HTTP to IP addresses: `NSAllowsLocalNetworking`. Loopback
  needs no Local Network permission; LAN addresses do (`NSLocalNetworkUsageDescription`); Tailscale
  addresses go through a VPN interface and are not gated.

## Still to verify on device

1. ⌥Space event delivery.
2. ⌘V into the panel while Nibble is inactive.
3. ~~Pinyin candidate window above or below the panel.~~ Verified 2026-11-01: at `.floating` the
   candidates sit above the panel. Over another app's full-screen Space they did not show at all:
   on macOS 27 the candidate window is an `NSPanel` made in the client's process (level 20, a new
   one per composition, `collectionBehavior` 0), and it opened on the desktop Space. Setting
   its Space rules once it is showing does not move it, nor does ordering it front again;
   `addChildWindow` does (a child shares its parent's Space). Activating the app neither helps nor
   leaves the full-screen Space. The input source badge (`TUINSWindow`, kept between uses) works
   with the rules set before it shows. ChatGPT's and Codex's floating windows have the same bug.
4. Panel over another app's full-screen Space; behaviour with Stage Manager.
5. Global mouse monitor without permission.
6. Screen Recording re-consent frequency; picker without a grant.
7. A real screenshot-thumbnail drag.
