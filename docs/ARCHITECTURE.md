# Architecture

Nibble is a macOS app in the Dock and the menu bar (or the menu bar only). A global shortcut opens
a small floating chat panel that stays above other windows on every Space, including full-screen
ones; a main window holds home (usage), history and settings. The panel is a light board: one
board of square cells whose light shows what the panel is doing, and the main window stands on a
board of its own. It talks to a chat backend: Hermes
Agent, any OpenAI-compatible endpoint, Google's Gemini API, Anthropic's Claude API, or a scripted
stand-in for trying the panel. Every backend keeps its settings; the reader switches between them
from the panel, the menu bar panel or the main window.

This document describes how the code is organised and where Nibble keeps data. Notes on the
Hermes API and on macOS live in [research/](research/).

## Layout

```
App/                 macOS app target: entry point and composition root (no logic of its own)
Sources/
  NibbleCore/        domain model and application logic, Foundation only
  NibbleBackends/    ChatBackend implementations (Hermes, OpenAI-compatible, Gemini, Claude,
                     scripted) and Backends
  NibbleStore/       everything written to disk, and the Keychain
  NibbleSystem/      macOS services without UI (hotkey, screen capture, image preparation)
  NibbleUI/          the interface: panel, main window, light board, menus, status item, strings, fonts
Tests/               one test target per module that has logic worth testing
scripts/             build, run, test, clean, screenshots, the demo recording and the README media
docs/                this file, research notes, the pictures the README shows (docs/media)
marketing/           full demo recordings (made by scripts/demo.sh, not kept in git)
project.yml          XcodeGen spec for the app target (Nibble.xcodeproj is generated)
Package.swift        the NibbleKit package that holds all modules
```

## Dependency rule

```
                 App (composition root)
      ┌──────────┬────────┼─────────┬──────────┐
      ▼          ▼        ▼         ▼          ▼
  Backends     Store    System      UI      (Core)
      └──────────┴────────┴─────────┘
                       ▼
                   NibbleCore
```

Every module depends on NibbleCore and on nothing else inside the package. Only the app target
imports several modules, and it does nothing except build objects and connect them
(`App/AppController.swift`). This keeps each module replaceable: the pixel-art UI can be built
against the scripted backend, and backends can be developed and tested without any window.

NibbleCore defines the seams as protocols:

- `ChatBackend` streams `ChatEvent`s for a `ChatRequest` (history, the new turn, an optional
  remote session id) and answers approvals. `BackendProvider` builds them from settings and
  deletes a conversation's remote session. Events: answer text, reasoning, an activity (thinking,
  searching, reading, looking, a tool, with an optional detail) and its end, waiting (a provider
  wait or a retry), an approval request, a replacement of the whole answer, token usage, the model,
  the remote session handle. Failures are `BackendError`s.
- `ConversationRepository` saves conversations and attachment bytes and applies retention.
- `SecretStore` keeps API keys (the Keychain in the app).
- `BackendProvider` builds the backend in use and tells the settings page about it (Hermes
  profiles, connection, where the key comes from); `SystemServices` captures the screen, prepares
  images and adds Nibble to the login items.
  NibbleBackends and NibbleSystem implement them; the panel only sees the protocols.

`ConversationSession` (NibbleCore) is the heart of the app: the current conversation, the draft,
pending attachments, sending, streaming, stopping, retrying, answering approvals, starting over,
and the rule that a conversation continues if the panel is summoned within `continueWindow` of
the last activity. While a reply is in progress it exposes its `ReplyPhase` (waiting, working on
an activity, waiting for the reader's OK, writing), when the phase and the current kind of
activity began, and the answer's speed; each finished reply keeps `ReplyStats` (wait, work and
write times, token usage, speed, model) for the statistics. It is `@MainActor @Observable`, so
views bind to it directly. `UsageReport` and `ConversationReport` (NibbleCore/Stats) turn saved
conversations into the numbers the home page and the panel's conversation page show; token counts
are the backend's where it reports them, estimated from the text otherwise.

## Backends

- **Hermes** (`HermesBackend`): the API server's chat completions route with a session of
  Nibble's own (`X-Hermes-Session-Id: nibble-…`), so Hermes keeps the conversation and each turn
  sends only the new message. This route streams everything the panel shows: reasoning
  (`delta.reasoning_content`), tool calls (`hermes.tool.progress`, mapped by tool name to
  searching, reading, looking or a tool), waits and retries (`hermes.status` lines starting with ⏳
  become waiting), approvals (`approval.request`, answered at `/v1/runs/{id}/approval`) and usage.
  An approval is answered once (`once`), for the rest of the conversation (`session`: Hermes then
  allows this kind of command without asking, offered when the event's `choices` include it), or
  denied; Nibble never offers `always`, which writes Hermes's permanent allowlist.
  Text streamed before a tool call is the model talking on its way and is moved out of the
  answer. Stopping closes the stream, which interrupts the run. A profile is a persona, reached
  under `/p/<profile>/` with its own key. See docs/research/hermes-backend.md.
- **OpenAI-compatible** (`OpenAICompatibleBackend`): `/chat/completions` with the whole
  conversation after a system message with the persona's instructions, images as data URLs,
  reasoning from `reasoning_content` or `reasoning`, usage from the last chunk.
- **Gemini** (`GeminiBackend`): `models/<model>:streamGenerateContent?alt=sse` with the key in
  `x-goog-api-key`, the conversation as `contents` (user / model), the instructions as
  `systemInstruction`, images inline; thoughts shown with `includeThoughts` (asked again without it
  when a model cannot think), usage from `usageMetadata`. A bad key comes back as 400
  `API_KEY_INVALID` and is treated as refused.
- **Claude** (`AnthropicBackend`): `/v1/messages` with `x-api-key` and `anthropic-version:
  2023-06-01`, the instructions as `system`, images as base64 blocks, `max_tokens` 8192; text and
  thinking deltas, input tokens from `message_start` (cache reads and writes included), output
  tokens from `message_delta`.
- **Scripted** (`ScriptedBackend`): waits, thinks, searches, reads and writes a fixed answer;
  `fail` and `ask` scripts end in an error or ask for an approval. Used with `-NibbleScript`.

The three model APIs are stateless: every request carries the whole conversation; turns with
nothing in them are left out where an API refuses them. Gemini and Claude have official addresses
used when the address is left empty. The connection check lists the API's models, which also
proves the key.

Personas: for the model APIs the reader writes personas of their own (`Persona` in Settings: a
name and a system prompt; none means no system prompt). `ConversationSession.instructions` carries
the persona's prompt into `ChatRequest.instructions`. A model that takes no system prompt (Gemma on
the Gemini API, older OpenAI reasoning models) refuses the request with a 400 that names the system
prompt or the instructions; `HTTP.reply` then sends it once more with the instructions in front of
the first question. Hermes answers as its profiles and ignores the instructions.

Keys: a key pasted in the settings page goes to the Keychain (service = bundle id, account
`hermes:<host>:<profile>`, `openai:<host>`, `gemini:<host>` or `anthropic:<host>`). With Hermes on
this Mac and no pasted key, the profile's own `API_SERVER_KEY` is read from its `.env`
(`HermesDirectory`, read only).

## The interface

`Interface` (NibbleUI/Shared) builds the panel (`PanelController`), the main window
(`MainWindowController`), the menu bar item and the app's menus around one `AppModel`: the
settings, the language and colours, the backend's state, the saved conversations, and the ways to
reach each window. The app target only builds it and forwards the hotkey and the Dock icon's
clicks. Each window has its own board and its own `LightRegistry`, handed to its views through the
environment; the shared controls (`IconKey`, `TextKey`, `Choice`, rows, plates) report to whichever
window they are in.

## The light board

`NibbleUI/Board` computes the light:
`Palette` (Violet in OKLCH, mixed in OKLab), `Motions` (the motions and moments), `Board` (one
value per cell per frame: motion with its erasing wave or crossfade, moments, typing light,
control lights, plates, stall and flash, warmth, cap; quantised to 24 levels and 12 hue steps)
and `BoardView`, which uploads the cell colours as a small texture and draws them with one Metal
fragment shader (lit square, ground in the gap). The panel's board view is as large as the panel
can get and pinned to its top, so it never resizes while the panel unfolds or is resized. While
the size is between whole cells, the scene and the shader shift the rows and columns by the
remainder (`BoardScene.shift`, `BoardView.shift`): the cells stay put relative to the side that
does not move, the bar's while the chat unfolds, the opposite side's while an edge is dragged.

Frames come from a display link each board view owns (`NSView.displayLink`, common run loop
modes), which calls MTKView's `draw()`; MTKView's own timer is never used. After hours of running
that timer could stop for good, its dispatch source cancelled while its display link kept firing,
which froze the main window's board with nothing in the app able to notice.

Every registry entry remembers the view that reported it, and a view that goes away removes only
its own: when one view takes another's place under the same name (the next transcript in
history), the new one reports before the old one leaves. Plates are drawn dimmest first, so a plate under text shows on a dim box that holds it (the
history transcript's). The waiting light (`Motion.circuit`) runs a light round the board along its
edges, brightest at the edge and reaching in wider and fainter. The reading light (`Motion.page`)
lights a page of lines laid out like text (words, paragraphs), then a band sweeps down and wipes
them, leading with a short fade and trailing a long one, and the next page lights up. In the slow tunnel and the warp
each star keeps a pace of its own (0.6–1.8 times the field's) and draws a tail as long as its pace;
at the tunnel's slow speed the tails are drawn longer, so a small window still reads as a tunnel.

On the strip (`BoardScene.strip`, `BoardGeometry.strip`) the panel's own light plays, its idle the
light chosen in settings as everywhere else, and the motions that need room take a shape of their
own: three lights run round the edges a third of the way apart (one would read as a bar sliding to
and fro), the terminal prints a line a row, the reading page is the two middle rows, the
starfield is pressed flat to the strip with fewer stars, the search surge and the lava's bodies are
sized to the strip. The strip names two places through the registry's anchors: its key, where the
answer's ripple starts (narrower and brighter there), and the end of its words, where the cursor
stands while the reply asks. A failure there holds the light without the flash and turns the lit
cells to the warning colour as the red spreads out from the key over 0.7 s (`BoardScene.alert`).

Every frame `PanelController` works out the panel's light state (`LightLanguage`: idle, waiting,
think, deep after 2.5 s, search, read, look, tool, attention, writing, error), the warmth (error,
or the answer's speed) and the scene: lights under controls, plates under the reader's text and
under errors, the scroll position, the page sweep, a dragged file. Views report their geometry and
hover to a `LightRegistry` that nothing observes, so reporting never re-renders anything. The send
key's 5 × 5 display is also advanced by the frame loop and redraws only when a dot changes.

Cost (Release, M-series): a frame computes in about 0.5 ms; slow light runs at 30 frames a
second and frames in which no cell changed are not drawn; waves, moments, typing and the panel's
own movement get 60. An open panel at rest with the lava lamp playing uses about 5 % of a core;
a hidden panel draws nothing. The main window at its default size (about 5,700 cells) uses about
6.5 % in front, about half that behind other windows, nothing when unseen.

## Panel behaviour

Implemented in `NibbleUI/Panel`:

- The hotkey summons the panel when hidden, refocuses it when visible but unfocused, and puts it
  away when focused. Esc closes the source menu, leaves the conversation page, stops editing a
  question, or puts the panel away.
- The latest question can be edited with a backend that takes the whole conversation each time
  (a model API): under the pointer an Edit key shows to its left; it puts the question's text and
  images back in the composer (what was being typed comes back on cancel), dims the question and
  its answer, and sending replaces them (`ConversationSession.editLastQuestion`). Hermes keeps the
  conversation in its own session and its API server cannot take a turn back
  (`ChatBackend.keepsConversation`), so its conversations offer no Edit key; switching to Hermes
  mid-edit ends the edit.
- Empty, the panel is the composer alone (the bar, six cells tall, seven at the large text size);
  sending unfolds it upward into the chat, the bar staying where it is, as the send's band of light
  rises. The chat keeps one height whatever its content, remembered (`Settings.panelHeight`, 240–800
  pt, whole cells), as is the width (`Settings.panelWidth`, 400–720 pt). Any edge or corner changes
  the size (`PanelEdges`, above the content: 8 pt edges, corners reaching 20 pt along both sides;
  the bar only sideways); the dragged sides follow the pointer exactly, read from the events' own
  screen positions, the opposite sides stay put, and the size settles on whole cells when let go.
  The edge under the pointer lights its outer row of cells, brighter while dragged; a corner is
  brightest at the corner and fades along both sides. Closing (×, Esc, the hotkey) folds the chat
  back down into the bar and fades it out at the bar's height; summoning unfolds it again. New chat
  folds it into the bar and starts over.
- The panel opens where the reader last left it: the bar's bottom left corner is remembered across
  launches (`NibblePanelPlace` in the app's defaults) and kept inside that screen; a chat that
  would not fit above the bar moves down while it is open, and the bar's place stays. The first time,
  the whole chat is centred on the screen under the pointer.
- The panel may go anywhere on its screen but the menu bar, over the Dock too: it floats one level
  above the Dock (`FloatingPanel.aboveDock`). A drag stops at the top and bottom of that room
  (`FloatingPanel.room`, through `constrainFrameRect`) instead of being pulled back after each move.
- The input's placeholder makes way as soon as anything is typed, an input method's unfinished
  text included.
- The typing light answers every key an input method composes (pinyin before its characters go
  in), not only the characters that land, so typing Chinese lights the board as much as English.
- The input method's own windows (Pinyin's candidates, the input source badge) open in Nibble's
  process without the panel's Space rules, so over another app's full-screen Space they opened on
  the desktop, out of sight. While the composer takes keys, the panel makes a showing one its child
  window (children go with their parent's Space and sit above it) and gives every one its Space
  rules for next time (`FloatingPanel.followInputMethod`); so too on a change of input source and on
  Caps Lock, which show the input source badge.
- There is no pin: clicking elsewhere puts the panel away only while it is empty (no messages,
  draft or attachments).
- The chat folds into a strip at its top right corner (`PanelStrip`; the header's collapse key,
  ⌘M) so it stops covering what is underneath while a reply runs. The strip, four cells tall and as
  wide as its asking line needs (31 cells for Chinese at the small size), shows the send key's
  display, the status line (ERROR after a failure, the thinking time after an answer), Allow and
  Deny while the reply asks (allowing for the whole conversation is in the chat only, to keep the
  strip narrow), then unfold and close where the header's collapse and close keys were,
  so the key under the pointer turns into its opposite. Folding eases every edge in and out over
  0.36 s (`PanelController.foldSeconds`), so a large chat starts closing in gently; unfolding eases
  at the pace the chat unfolds from the bar (`shapeTau`). The chat's pages keep the chat's size,
  held at the top right corner, and fade out as it folds (the strip's content fades in last, and
  the other way round), and the cells keep to that corner. The strip takes clicks but never the
  keyboard (`FloatingPanel.takesKeyboard`). Folding hands the keyboard back by stepping the panel
  out and back in front in the same moment with the window's own fade turned off (with the fade
  the panel flickered); the app underneath, still the active one, does not take the keyboard back
  when asked to activate. A click on the strip, its unfold key or the hotkey unfolds the chat where it was, moved as
  far as the strip has been and kept on the strip's screen; closing the strip opens the chat there
  next time.
- The panel is a non-activating `NSPanel`: it takes keyboard input while the user's app stays
  active, and Nibble never activates itself for it, since activation would pull the user out of a
  full-screen Space. It never moves by its background (SwiftUI would let a press on almost
  anything move it, the space around text included). Its empty space moves it instead: a
  `DragSurface` behind the whole panel and behind the conversation's content follows the pointer
  once it moves a few points, and a click there gives the composer the keyboard. Text and images
  are content in front of it: each answer's block (as wide as its longest line, the gaps between
  paragraphs included) and the reader's plates select, images drag out to other apps, keys take
  their clicks. In the input only the typed text selects; the rest of the field, all of it while
  empty, moves the panel and a click there puts the caret.
- The header's left shows the service over the persona in the pixel face's smaller 10 px cut,
  leaving room for the header's keys; a click opens the source menu (`SourceMenu`, shared with the
  menu bar panel and the main window): the services with their models, the personas of the one in
  use, and a way to settings to manage personas.
- Images can be pasted into the input or dropped on the panel; the capture key attaches the
  display under the panel without Nibble on it (Screen Recording permission). Images are scaled to
  at most 1568 px and sent as PNG (screenshots, drawings) or JPEG (photos).
- The header's keys are new chat (+), the conversation page (=), collapse (a block gone into the
  corner) and close (×), 3 × 3 pictures in the send key's dots; the capture key beside the send key is a 5 × 5 picture, dimmer at rest. The conversation page shows this conversation in numbers
  (questions, tokens, speed, wait, context, failures, each answer's speed as a dot chart) and the
  most recent other conversations, which it opens in the chat; its foot opens the main window's
  history and settings.

## The main window

`NibbleUI/Main`: an ordinary window (system window buttons, resizable, remembered frame) whose
content runs under a transparent title bar on a board of its own. The board plays the idle light
chosen in settings (lava lamp, stars, a slow tunnel of stars, glimmer or ripples), sweeps a band of light
across when the page changes, lights hovered rows and keys, and puts the selected sidebar item and
history row, and the reader's text in a transcript, on plates of whole cells. While the window is
covered or on another Space it draws nothing and looks again four times a second (its loop is
never paused there, so the board cannot be left frozen); behind other windows it runs at 15 frames
a second.

- Sidebar: Nibble's mark, home, history and settings; at the foot who answers (the service with
  the connection's lamp, the persona under it; a click opens the source menu above) and About.
- Home: while no service is set up (a first launch without Hermes, say), a line on a plate with a
  key to the settings; then figures in a dot face (asked today, tokens in seven days, average speed, average wait),
  the last fourteen days as a dot chart (questions or tokens; the pointer reads a day), personas,
  the latest conversations.
- History: every saved conversation by day, searchable (the field on a dim plate as wide as the
  list, which takes about a third of the page, 300–400 pt); the picked one read in full at a
  reading width (at most 640 pt, a large window leaves room on the right) on a box of dim cells
  that follows it, its text selectable, to continue in
  the panel or delete (a second click confirms). A row deletes from the list too: under the
  pointer it shows a × at its right end; a click turns the row's cells, its second line and the ×
  to the warning colour, a second click on the × deletes, leaving the row cancels; the next
  conversation opens if it was the open one. At the end of the list, clear all history in the
  warning colour on warning cells (a second click confirms). The transcript scrolls inside its
  box, which stops 20 pt short of the window's foot; its text ends 12 pt inside the box.
  Deleting a conversation also deletes its Hermes session (see "Runtime data").
- Settings, one page: connection (the service: Hermes, OpenAI-compatible, Gemini or Claude; its
  address, key, and the Hermes profile or the model and the persona), appearance (mode, colour,
  text size, idle light, language), quick chat (shortcut, send key Return or ⌘Return, how long a
  conversation continues, whether screen capture is allowed with a way to System Settings), app
  (show in the Dock, open at login, as dot switches), data (retention, location). Personas
  (`PersonaEditor`): a chip for each and one to add, then the persona in use, its name and system
  prompt each on a box of dim cells, with delete, revert and save; unsaved changes are kept per
  persona while the page is open. Section titles are in the larger pixel face with a steady lamp of one board cell
  before them; the row labels are set in beneath. On the right, centred on the window's height, a
  ruler of short bars of two lit cells, one per section: the section in view is the brightest, the
  pointer lights a bar and names it, a click scrolls there. Lamps and bars light the nearest whole
  cells wherever they fall. The shortcut row shows a conflict, when there is one, with a lamp in the
  warning colour and a line saying what else uses the combination (see "Shortcut conflicts").
- About: a card on a plate of cells with the icon, the name, what Nibble is and the version; the
  app menu's About opens it too.

Colour themes (`Settings.colorTheme`): Violet, Nibble's own, and teal, blue, rose, orange and
amber. Each is a base hue, a turn to the hot end of the board's hue axis and an accent fitted in
each appearance (`ColorTheme.hues` in Palette.swift); every board and the text take them at once.
Warnings and errors have a colour of their own (Violet's rose, red for the other themes), a row of
fills after the hue steps.

The idle light (`Settings.background`) is one light at rest for the whole app: behind the main
window and the menu bar panel, and in the panel while nothing happens. Stars stay dimmer in the
idle panel than thinking's stars, so a question still changes the light.

Text size (`Settings.textSize`): small (the designed size), medium and large. Reading text
(messages, the input, code, tables, transcripts) grows to 16 and 18 pt, the pixel face to 15 and
18 (12 and 18 are whole device pixels a face pixel; 15 is a little softer, so the main window
follows every step), with the keys, rows and titles that hold it. The empty bar keeps its six
cells at the medium size (narrower margins take the taller line) and grows to seven at the large.
Views read the sizes from `Typeface`, which reads an observed `TextScale`, so a change redraws in
place.

## The menu bar panel

The menu bar item opens a small light board of its own under it (`Status/MenuPanel.swift`), in
place of a system menu: Nibble's mark and who answers (a click opens the source menu), today's
questions and the week's tokens in the dot face beside the last seven days as a dot chart, the
latest three conversations (a click continues one in the panel; "More" opens history), and four
keys with dot icons, each on a plate of 14 × 4 whole cells: new chat, show quick chat, open Nibble
(the main window, where settings are too) and quit on warning cells. It blooms open from the
middle, plays the idle light, brightens the key under the pointer, and closes on a click
elsewhere, Esc or a second click on the item.

## Shortcut conflicts

`SystemServices.hotKeyConflicts` (NibbleSystem/HotKeyConflicts.swift) finds what else answers the
summon shortcut: macOS's own shortcuts (com.apple.symbolichotkeys, with macOS's defaults for those
never changed), shortcuts nearly every app shares (⌘C, ⌘Q, ⌘Tab…), other apps' shortcuts saved by
the common KeyboardShortcuts library in their preferences (ChatGPT, for one), and anything holding
the combination exclusively (an exclusive Carbon registration is refused). Apps that take keys
another way cannot be seen: Carbon lets several apps register the same combination without a
word. Nibble keeps the shortcut either way and only shows the conflict.

## The app

Nibble shows in the Dock by default (`Settings.showInDock`; the bundle starts as a UI element and
switches its activation policy at launch, so a menu-bar-only Nibble never flashes in the Dock).
Clicking the Dock icon opens the main window; closing it leaves Nibble running. A launch by the
reader opens the main window, a launch at login stays quiet. Open at login uses
`SMAppService.mainApp` (the system keeps that state, under Login Items in System Settings). The
menus (app, Edit, Window) follow the interface's language; Edit routes ⌘C, ⌘V and the rest to the
panel too. The app icon (`App/AppIcon.icon`, an Icon Composer document with one flat layer and no
Liquid Glass) shows two spots of light on the board.
The menu bar item and the sidebar show the same picture as a 6 × 6 dot mark (`NibbleMark`), the
menu bar one as a template image.

## Runtime data

All user data lives in one folder, outside the app bundle and outside this repository:

| What | Where | Bounded by |
|---|---|---|
| Settings (personas included) | `~/Library/Application Support/<bundle id>/settings.json` | a single small file |
| Conversations | `…/<bundle id>/conversations/<id>/conversation.json` | retention policy |
| Attachments | `…/<bundle id>/conversations/<id>/attachments/` | deleted with their conversation |
| API keys | Keychain, service `<bundle id>` | one item per backend kind and address (and Hermes profile) |
| Main window frame | the app's defaults (`NSWindow Frame Nibble.main`) | one line |
| Where the panel was left | the app's defaults (`NibblePanelPlace`; the older `NibblePanelOrigin` is read once and removed) | two numbers |
| Logs | unified logging, subsystem `<bundle id>` | managed by the system |

The bundle id is `com.glimmer.Nibble` for release builds and `com.glimmer.Nibble.dev` for Debug
builds, so development never reads or writes the data of an installed release. The
`NIBBLE_DATA_DIR` environment variable points the app at any other folder.

Retention runs at launch: conversations older than `maxAgeDays` (default 30) or beyond the newest
`maxConversations` (default 200) are deleted with their attachments. Attachment files no message
refers to, and folders of conversations that were never sent, are removed once they are a day old.

A conversation answered by Hermes also lives in Hermes, as a session of the profile that answered
(`Conversation.remoteSessionID` is `profile/session`). Deleting the conversation in history, or
clearing all history, deletes that session through the API server (`DELETE
/api/sessions/{id}`, with the sessions Hermes continued it in after compressing it). Hermes
removes the session's messages, its transcript and request dumps, and the images sent with it.
Files the agent wrote while answering belong to no session: they sit in the profile's
`cache/scratch`, which Hermes clears a day after the last write. A Hermes that cannot be reached
keeps its copy (the failure is logged). Retention does not touch Hermes.

Files are JSON, pretty-printed with sorted keys and millisecond ISO 8601 dates, written
atomically. Decoding settings fills missing keys with defaults, so adding a setting never breaks an
existing file.

## Building

| Command | Result |
|---|---|
| `scripts/build.sh [debug\|release]` | generates `Nibble.xcodeproj`, builds, prints the app path |
| `scripts/run.sh [app arguments]` | builds Debug and relaunches it |
| `scripts/link.sh [--remove]` | builds Release and links it as `/Applications/Nibble.app`, so Nibble opens from Applications and runs the latest build (a symbolic link into `build/`, which Spotlight does not index, so no copies show up) |
| `scripts/release.sh` | the release for GitHub: built with its own DerivedData, signed with the Developer ID of `NIBBLE_TEAM`, checked for paths of the Mac that built it, notarized with the notarytool profile `NIBBLE_NOTARY_PROFILE` (both in `local.env`), stapled and zipped with its SHA-256 in `build/release/` |
| `scripts/test.sh [swift test arguments]` | runs the package tests, without any window: the everyday check after a change |
| `scripts/check.sh [panel] [edges] [main] [menu]` | builds Debug and runs the on-screen self-test (scripted backend, throwaway data), only what code alone cannot see: window heights and places, what a press lands on, the light through a reply; prints the JSON report. Its windows take the keyboard, so it runs only for changes to window behaviour, and only the part concerned |
| `scripts/shot.sh PAGE NAME [app arguments]` | screenshots a page of the Debug app (home, history, settings, about, sheet, menu, source) with made-up conversations from `scripts/demo-data.py` (`en` for English ones) and the scripted backend; data in `build/shots/data`, pictures in `build/shots/` |
| `scripts/demo.sh [THEME]` | records the panel for marketing in one colour theme (violet if left out; `marketing/nibble-demo-en-THEME.mp4` and `.marks`, the moments' times; about a minute, on a backdrop in the theme's hue): the Debug app plays English questions through every light (thinking straight into the tunnel, played faster than usual so it reads in a few seconds) (`PanelDemo`, scripted backends) while `scripts/record.swift` films only Nibble's windows with ScreenCaptureKit on a plain background; the panel takes the keyboard while it runs |
| `scripts/hero.sh [row\|grid] [webp\|mp4]` | cuts the moving picture from the four demo recordings: the same seven seconds side by side, each colour at a different moment (sent and unfolding, the tunnel, a command allowed and running, a failure retried), found by the moments the recording marked, at exactly half size so the cells stay even. A clip in which the recording stood still for more than 50 ms (a busy Mac drops frames) stops it, naming the colour to record again. With no arguments, the README's: in a row, lossless WebP, `docs/media/hero.webp`; `grid mp4` is a two-by-two video for upright formats, `marketing/nibble-hero-grid.mp4` |
| `scripts/screens.sh [zh\|en]` | takes the README's screenshots in one language (the chat, the strip, the menu bar panel, home, history; made-up data, scripted backend) and lays them out as `docs/media/panel-LANG.png` and `main-LANG.png` |
| `python3 -I scripts/mock-backend.py [port]` | a stand-in for Hermes's API server and an OpenAI-compatible endpoint (default port 8650), for trying the real network code |
| `scripts/clean.sh [--dev]` | removes build products; `--dev` also the Debug app's data and permissions |

Every build byproduct stays in `build/` (git-ignored): DerivedData, cloned packages, the SwiftPM
scratch folder, the clang module cache, temporary files, the last build log and the recorder.
The scripts point `TMPDIR` into `build/` and remove it on exit. The Release build ("Nibble", `com.glimmer.Nibble`)
and the Debug build ("Nibble Dev", `com.glimmer.Nibble.dev`) keep separate data, so tests and
screenshots never touch the data of the Nibble in use.

Signing: copy `local.env.example` to `local.env` (git-ignored) and set `NIBBLE_TEAM` to an Apple
Developer team; builds are then signed with that team's development identity, so privacy
permissions (Screen Recording) survive rebuilds. Without it, builds are signed ad hoc.

Useful launch arguments: `-NibbleShowPanelAtLaunch YES` shows the panel right after launch;
`-NibbleScript sample|fail|ask` answers from a script instead of the configured backend;
`-NibbleAsk "…"` sends a question at launch; `-NibblePage home|history|settings` opens the main
window on a page (also `about`), `-NibblePage sheet` the panel's conversation page,
`-NibblePage menu` the menu bar panel and `-NibblePage source` the panel's source menu (with
`-NibbleAsk`, so the chat's header shows); `-NibbleWindowFile <file>` writes where the window in
front is once it has settled (scripts/shot.sh); `-NibbleSelfTest <file>` runs the self-test of the
panel and the main window (see `scripts/check.sh`). For screenshots outside scripts/shot.sh, point
`NIBBLE_DATA_DIR` at a folder outside ~/Documents, ~/Desktop and ~/Downloads, which macOS guards
with a permission prompt.

## Conventions

- Swift 6 language mode with complete concurrency checking. UI and session state on the main
  actor; storage behind an actor.
- Code, comments and documents in English. User-facing text lives in one table,
  `NibbleUI/Theme/Strings.swift`, with Chinese and English side by side; the panel follows the
  system language unless the reader picks one in settings, and switches at once.
- No third-party dependencies until one clearly pays for itself. The bundled font is Fusion Pixel
  (SIL Open Font License; its notices sit beside the font files).
