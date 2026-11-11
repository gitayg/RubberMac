# RubberMAC

Formerly Screen Tools. The log (`~/Library/Logs/ScreenTools.log`) and the data folders keep the old name.

A macOS menu-bar app (Swift/AppKit, no Xcode project) with Windows habits and display helpers. Clicking its menu-bar icon opens a settings panel with all of it:

- **Big Clock and pre-lock warning:** shows the Big Clock screen saver, warns (and dims the screens) before the screen saver locks.
- **Brightness:** sliders for each screen (DDC, or software dimming behind a DisplayLink dock), plus ⌃⌥⌘↑/↓.
- **Window snapping:** ⌘ + arrows snap to a grid you choose (2–4 columns × 1–3 rows), maximize and minimize, and move to the next screen. ⌘M minimizes all windows and ⌘⇧M brings them back.
- **Dock in full-screen apps:** moving the pointer to the Dock's edge brings it up, without the firm push macOS wants there.
- **Pick a window from the Dock:** clicking the Dock icon of an app with two or more windows opens a menu of them beside the icon, each with a picture of the window and its title, instead of bringing the whole app forward; clicking one goes to that window, even if it's minimized, hidden or on another desktop. Esc, a click elsewhere or another click on the icon closes it. Apps with one window, ⌘/⌥/⌃/⇧-clicks, right-clicks and dragging icons work as before.
- **Eye Color Camera:** recolours your eyes live on video calls, to a real eye colour (blue, ice blue, deep blue, blue green, green, gray, hazel, amber, brown) rather than a painted-on one. RubberMAC runs [camrelay](https://github.com/gitayg/camrelay) as a helper, which tracks your irises and sends the picture to the OBS virtual camera; pick that camera in Zoom, Meet or Teams. Its page in the settings panel turns it on and off and sets the colour, strength and camera, opens camrelay's calibration, and can turn it on when RubberMAC starts. While it's on, the page also shows a preview of what others see, read from OBS Virtual Camera (never the real camera) and only while the page is open; it needs the camera permission. Needs camrelay installed (its README) and OBS's virtual camera.
- **Camera in front of the screen:** mark where a camera on a stand covers part of a screen, and snapping keeps windows clear of it. A toggle turns this on and off.
- **PC keyboard habits:**
  - Alt-Tab switches windows (most recently used first, so a quick Alt-Tab goes back to the previous one; the order survives RubberMAC restarting) or apps. It lists the windows on every desktop and full-screen Space, and of hidden apps; picking one on another Space switches there. It shows a grid of window pictures sized so every window fits on the screen, each with its app icon, title and a small map of where the window is; clicking a tile switches to that window. Pictures need Screen Recording; without it each tile shows the window's place on the screens, with its app icon. In window mode ⌘Tab switches windows too, so each of an app's windows (say, three Teams windows) can be picked; a switch on the Keyboard page turns that off and gives ⌘Tab back to macOS.
  - Ctrl-C/X/V/Z copy, cut, paste and undo; Ctrl stays Ctrl in terminals, VS Code and remote desktops.
  - Ctrl-←/→ move by word, and Home/End go to the start and end of the line.
  - Left Alt-Shift switches the input language.
  - Paste a path in Finder (⌘V or Ctrl-V) to go to that folder in the same window, without ⌘⇧G. A file's path goes to its folder and selects it. Plain paths, `~`, `file://` links, quoted paths and terminal-style `My\ Folder` all work. Pasting into a text box in Finder and pasting copied files work as before.
  - Delete in Finder moves the highlighted file to the Trash (⌘Z puts it back), with either delete key. Renaming, search, the address bar and the writing pad keep their delete key.
  - An address bar under the toolbar of the front Finder window shows the folder's path; paste or type a path there and press ↩ to go to it.
- **Writing pad:** ⌘⇧Space in Teams, Outlook or any app opens a pad (taken before Siri sees it, so holding it doesn't bring up Siri) to write the reply in. Apple's on-device model fixes it as you type, and ↩ pastes the fixed text where you were typing and leaves it on the clipboard. Each reply is saved with the text of the window it answered, read from the screen.
- **Mouse:**
  - Pointer speed up to 16 and wheel speed ×0.5–×8, each remembered per mouse model.
  - Hold the wheel and move to scroll.
- **Window layouts:** remembers window positions for each monitor setup.
- **Updates:** checks [this repo's releases](../../releases) at launch and every six hours, then installs and relaunches.

## Install

Needs macOS 27 or later, on a Mac with Apple silicon.

1. Download `RubberMAC-<version>.dmg` from [Releases](../../releases), open it and drag RubberMAC to Applications.
2. Open RubberMAC. It lives in the menu bar, with no Dock icon.
3. It says why it needs Accessibility, then macOS asks: allow it under System Settings → Privacy & Security → Accessibility. The keyboard, window and Dock features need it.
4. Next it asks for Screen Recording, which is optional: it adds window pictures to Alt-Tab and the Dock menu, and the screen text the writing pad reads. Not Now leaves it for later, on the Permissions page of the settings panel. Apple Intelligence is what the writing pad's fixes need.

Everything runs on the Mac. Its only network traffic is checking GitHub for updates and downloading them.

## Build

```bash
./build.sh
```

`build.sh` compiles `src/*.swift` with `swiftc`, then installs `~/Applications/RubberMAC.app`, signs it with the Developer ID and relaunches it. The Developer ID signature is what keeps the Accessibility grant across rebuilds.

## Release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Add a `## <version>` section to `CHANGELOG.md`.
3. Run:

   ```bash
   ./release.sh
   ```

`release.sh` does the rest:

- runs `dmg.sh`, which builds into `build/`, signs with a secure timestamp, notarizes and staples;
- publishes `RubberMAC-<version>.zip` and the DMG as release `v<version>` on this repo (the one `origin` points to), using that version's changelog section as the notes;
- installs that same build into `~/Applications`.

One-time setup: run `xcrun notarytool store-credentials screentools`, be logged in to gh as the repo's owner, and name your Developer ID certificate in `.signing-identity` (ignored by git) or `SIGNING_IDENTITY`. `build.sh` needs that too.

To hand the app to someone without publishing an update, run `./dmg.sh` instead. It builds the version in `Info.plist` into `dist/RubberMAC-<version>.dmg` (the app and a link to Applications). It notarizes and staples the app, then the image, so both open on another Mac without a warning. It publishes nothing and leaves the installed app alone. It uses the same `screentools` notarytool profile.

The release is built and signed on this Mac, not in CI. Signing in CI would mean exporting the Developer ID key into GitHub secrets.

## How updates are checked

- `UpdateFeed` reads GitHub's latest-release API for this repo. A release holds a zip, which the updater downloads, and a DMG for installing by hand.
- `UpdateInstaller` downloads the zip and unpacks it next to the installed app. It then refuses the download unless all of these hold:
  - its version matches the release;
  - its version is newer than the running one;
  - it passes the running copy's own code requirement, as macOS reads it from the signature: the same bundle ID, signed with the same developer's Developer ID.
- If every check passes, it swaps the new app in and relaunches.

## Self-tests

Run inside the signed app so its permissions apply:

```bash
open -n --stdout /tmp/st.txt "$HOME/Applications/RubberMAC.app" --args --selftest mouse
```

| Test | Reports |
|---|---|
| `ddc` | brightness over DDC |
| `windows` | the window switcher's list, by app and window number (never titles), with which Space each is on; `--own-window` also moves a window of its own to another Space and hides it |
| `switch` | switches between real windows and checks Alt-Tab comes back to the one it left; moves focus, then puts it back |
| `finder` | which pasted text counts as a path, then a Finder window of scratch folders: a folder path moves that window, a file path selects the file, and the search field, ⌥⌘V, plain text and copied files are left to Finder. Hands ⌘V to the handler rather than typing it, but closes its window with ⌘W, so don't type while it runs. Asks once to let RubberMAC control Finder |
| `finder-bar` | the Finder address bar's place under the toolbar or tab bar, on any screen, and which typed text counts as a path; with `live` after it, a Finder window of scratch folders: the bar shows the folder's path, ↩ moves the window, and it hides when the window is minimized. Closes its window with ⌘W, so don't type while it runs |
| `finder-trash` | when Delete counts, then a Finder window of scratch files, handing the delete keys straight to the handler (a tap doesn't see posted keys on this macOS) and posting what it passes on: Delete and ⌫ trash the highlighted file and ⌘Z brings it back; renaming, a RubberMAC panel with the keyboard and holding the key trash nothing more. Presses a delete key only with Finder in front and exactly the scratch file highlighted; removes its files from the Trash, or says it couldn't. Skipped while the screen is locked, a full-screen app's desktop is showing, or the Mac was used in the last 20 s |
| `padkeys` | which keys the ⌘⇧Space handler takes, then ⌘⇧Space held 0.8 s through a tap of its own (no Siri) and without it (Siri's alert comes up; close it with OK). Opens and closes the pad |
| `dock` | in a full-screen window of its own, a quick move of the pointer to the bottom edge, without and then with the helper: the Dock stays hidden, then comes up. Moves the pointer, then puts it back |
| `dockmenu` | which clicks the Dock handler holds back and which it hands on (a drag goes on as the press, then the move); that every running app's Dock icon leads to its app; then with a helper copy of the app (its own Dock icon and three windows): a click without the picker brings the app forward, with it opens the menu of 3 above the icon while the app stays behind, a second click, Esc and a click elsewhere close it, each row shows the app's CPU and memory, a row goes to its window, and with one window left the click reaches the Dock. Brings up the Dock and clicks, then puts the pointer back. Skipped while the screen is locked, a full-screen app's desktop is showing, or RubberMAC is running with its Dock menu on. `nolive` stops after the first part; a folder (ending in `/`) as the last argument saves a picture of the open menu there |
| `dockmenu-ui` | the Dock window menu off screen with made-up windows: rows fit the screen, its place beside the icon for each Dock side, each copy's CPU and memory line on that copy's rows only and inside the row at the smallest pictures, clicks on a row, a picture arriving late; draws it to a PNG (path as the next argument) |
| `usage` | per-process CPU and memory: copy names from `--user-data-dir`, this process's command line read back, a busy thread and a busy child process each reading near 100% (rusage times are Mach ticks, converted), a child's time kept after it quits, the line's wording, and that every running app can be sampled. Needs no permission |
| `tap` | whether a busy main thread holds up keys: posts an F18 of its own (swallowed, so no app sees it) while the main thread sleeps 0.4 s, with the tap on the main thread and then on its own |
| `previews` | the saved focus order (kept within a boot, dropped after one); that every open window the switcher lists has a place on a screen; that a click anywhere on a tile (picture, title, map) picks that window; draws the switcher off screen with made-up windows and pictures to a PNG (path as the next argument); with Screen Recording, takes a picture of every listed window and reports counts and timing |
| `previews-fullscreen` | three striped windows of its own, each put in full screen over the one before: ScreenCaptureKit alone takes no picture of the first, and the switcher's pictures still have one, with the stripes, no bigger than the switcher shows it; the second asks not to be captured and gets none. Takes them out of full screen and closes them. Switches Spaces, so run it hands-off; skipped while the screen is locked or a full-screen app's desktop is showing |
| `permissions` | when RubberMAC asks for Screen Recording by itself (once, after Accessibility, not if it has it), and that each message says why and offers Not Now. Shows nothing |
| `eyepreview` | which camera the Eye Color Camera's preview would read (only OBS's virtual camera; with only real cameras, none), the camera permission, and when it's allowed, how many pictures arrive from the virtual camera in 3 s. Never opens a real camera |
| `settings` | the settings panel with no permission needed: the Permissions page's words for each state, that every title and note of the old menu is on a page (each conditional one with its condition on and off), that every control's target answers its action (never pressing them; no stored setting changes), and on made-up pages a switch's click, a re-render keeping the page and scroll, search, the empty state and Esc/⌘W/⌘F; draws each page in light and dark to PNGs (folder as the next argument) |
| `settings-live` | the real panel under a real menu-bar icon: a click opens it, focus lands on the sidebar and the sidebar reaches the screen, ↓ moves the page, the permissions read for real without asking, Esc closes it and gives the front back, and a click on the icon closes it for good. Posts clicks and keys, then puts the pointer back; skipped while the screen is locked, a full-screen app's desktop is showing, or the Mac was used in the last 20 s. A folder as the next argument gets pictures of the panel |
| `update-trust` | which downloads the update check accepts: a copy of this app passes, and one that was altered or signed ad hoc doesn't, nor does any app whose path follows (say, one for another bundle ID). Needs no permission or network |
| `pad` | the writing pad end to end in a scratch TextEdit document, typing real keys: fix, ↩, ⌥↩, ⇧↩, Esc; closes the scratch document and puts the clipboard back. Stops if anything else takes the focus, so don't type while it runs |
| `camera` | the marked camera spot on each screen, and where ⌘↑/←/→ would put a window there (moves nothing) |
| `layouts` | saved layouts |
| `input` | input sources |
| `mouse` | each mouse's pointer speed (writes the same value back) |
| `update` | the release feed, without installing |
| `update-install` | installs a newer release over the app it runs from — use a copy |

The keyboard tap runs on a thread of its own, so typing never waits for the main thread (layout saves, Accessibility calls to a slow app). Its handlers decide there and hand any real work to the main queue; they read the frontmost app from `Frontmost`, not NSWorkspace.

Logs go to `~/Library/Logs/ScreenTools.log`. A key that waited more than 50 ms for the keyboard tap is logged as `keyboard tap: a key waited N ms` (never which key), at most once a second.

## Settings panel

- The menu-bar icon opens `SettingsPanel`, a `.transient` `NSPopover`; a click on the icon while it's open closes it. It activates the app so Esc and the search field work, and on closing with the keyboard goes back to the app that was in front.
- `AppDelegate.settingsPages()` (`SettingsPages.swift`) describes the pages as data (`SettingsPage`, `SettingsSection`, `SettingsRow`), afresh for each render, from the same conditions the menu used. Each row keeps its own `@objc` action; popups show copies of tagged `NSMenuItem`s, so the original arrives as the sender. `SettingsFacts` holds what they depend on besides `Settings`, so the self-test can build them under any condition.
- `SettingsRowView` draws one row and `SettingsDetailView` the page, in place when the page keeps its shape so a switch's animation isn't cut, and scrolling stays where it was. A re-render waits while a slider is being dragged.
- A row that takes over the screen, opens elsewhere or asks a question closes the panel first (`closesPanel`).
- `PermissionCheck` is the Permissions page's words for a reading, with no AppKit in it. Finder's side is read off the main thread (`FinderWindow.permission(ask: false)`), and the log has only `permissions: accessibility on, screen recording off, finder on`.
- The Eye Color Camera page reads `EyeCamera` through `EyeFacts`. Showing the page starts the camrelay helper (`prepare()`) so the camera list is ready, and checks once for the separate camrelay app; while the page is open, each change the helper reports re-renders it.
- `EyePreview` shows the page's preview: an `AVCaptureSession` on OBS's camera extension (picked by model or maker, so a real camera is never opened) into an `AVCaptureVideoPreviewLayer`. `updateEyePreview()` runs it only while the panel is open on that page and camrelay is sending a picture (`state == .on`), and stops it on any other page, on closing, and when the camera goes off.
- The panel's window belongs to RubberMAC, which the switcher, the Dock menu and saved layouts all leave out by process (and by `.regular` activation policy).

## Window switcher pictures

- The panel takes clicks without taking the focus (a non-activating panel, tiles accept the first click); a click on a tile picks that window, as letting go of Alt would. Without Screen Recording a line under the tiles says how to allow it.
- `SwitcherPanel` lays the windows out as a grid on up to 96% of the screen under the mouse, trying every column count for the largest tile (pictures up to 300 points wide) that fits them all; only below 60 points would it scroll. `SwitcherTileView` is one tile.
- `WindowThumbnails` takes a picture of each listed window, fitted to 300 × 188 points, with ScreenCaptureKit when the switcher opens, all at once, and hands each to `SwitcherPanel` as it arrives. The list opens with the previous pictures and the app icon, so it never waits for them. Pictures are held in memory until the next switch and never saved or logged; the log has only how many were taken, how many came from the window server and how long it took. ScreenCaptureKit takes no picture of a full-screen window whose Space isn't showing (error -3811), so for an off-screen window it lists but gives none for, the picture comes from the window server instead (`SLSHWCaptureWindowList`, private, as AltTab uses it), shrunk to the same size. A window it leaves off its list gets no picture, and neither does one with `NSWindow.sharingType` `.none`, which is checked before that call.
- `WindowMapView` draws the screens in their arrangement, shrunk to fit, with the window at its place (its frame comes from Accessibility with the title, in the same round trip). It's the small map in each tile's caption, and fills the tile, with the app icon in the window's place, until there's a picture. Minimized windows are faded.
- `FocusHistory` is saved in the defaults (`focusHistory`) with the boot time, since window IDs start over at each boot.

## Windows on other Spaces

- Accessibility lists only an app's windows on the current Space. `SpaceWindows` asks the window server (private SkyLight calls, loaded with `dlsym` so a missing one falls back to the current Space only) for every window on each user Space, and which are ordered in; a window ordered out is a closed one the app keeps, and isn't listed.
- `SpaceElements` finds the Accessibility element of a window on another Space by its element number (`_AXUIElementCreateWithRemoteToken`), in the background, and caches it per app: when focus tracking starts, after a Space change, and after a snapshot finds a window it doesn't have.
- Picking such a window brings its app forward on that window (`_SLPSSetFrontProcessWithOptions`), which switches Space, then raises it.

## Full-screen Dock

- `FullScreenDock` watches pointer moves on a tap of its own thread. When the pointer reaches the Dock's edge (from `com.apple.dock`'s `orientation`) and the front window is full screen (`AXFullScreen`), it posts a few moves that keep going past the edge, as a push does, until the Dock is up or the pointer leaves.

## Dock window menu

- `DockClicks` is a handler on the pointer tap (session level, its own thread). On a left press it asks the Dock alone, through Accessibility, what's under the pointer (`DockItems`: about 0.1 ms, and only the Dock's own icons answer, so other clicks pay nearly nothing); a hidden Dock's icons sit below the screen's edge, where no click lands. For a running app's icon (`AXApplicationDockItem`, `AXIsApplicationRunning`) that a system-wide hit test also gives to the Dock (nothing over it there), it holds back the press and the release.
- `DockWindowPicker` lists that app's windows, as Alt-Tab does, while the button is down. With two or more it opens `DockWindowMenu` beside the icon; with fewer it hands the click on to the Dock (a press and a release where it was made, marked so the tap lets them through). Moving more than 4 points while pressed hands on the press and then the move, so the Dock sees a drag.
- `DockWindowMenu` is a non-activating panel; each row (`DockWindowRow`) shows the window's picture from `WindowThumbnails` (or its place on the screens with the app icon until there is one) and its title. Picking goes through `WindowFocus`, shared with Alt-Tab. Esc is taken by `DockMenuKeys` on the keyboard tap only while the menu is open.
- Under each title, `ProcessUsage` gives the app's CPU and memory (`proc_pid_rusage`: user + system time, including children already waited for, and `ri_phys_footprint`), summed over the process and everything it started (`proc_listchildpids`, recursively). The times are Mach ticks, converted with `mach_timebase_info`. Samples are taken off the main thread, first when the menu opens and then every second, since walking a tree of a hundred processes takes milliseconds. When the windows come from more than one process, each row also names its copy from that process's `--user-data-dir` (read with `KERN_PROCARGS2`). Nothing of it is logged.

## Finder paste

- `FinderPathPaste` is a keyboard-tap handler after `ClipboardKeys`, so Ctrl-V reaches it as ⌘V. It takes the ⌘V only when Finder is frontmost, the clipboard holds text (not copied files) naming something that exists, and Finder's focused element isn't a text box.
- `FinderWindow` moves the front Finder window with Apple Events (`set target of Finder window 1`, then `select` for a file), off the main thread. Under the hardened runtime this needs the `com.apple.security.automation.apple-events` entitlement (`ScreenTools.entitlements`, passed to `codesign` by `build.sh` and `release.sh`) and the user's one-time OK to control Finder, asked on the first paste.
- With the desktop in front instead of a folder window, or without that OK, the path opens in a new Finder window. Once the OK is refused, the Keyboard page offers the Automation settings.
- The log records which of these happened, never the path.
- `FinderAddressBar` puts a non-activating panel under the front Finder window's toolbar (or tab bar), kept just above that window and hidden when Finder isn't in front. It reads the folder with `FinderWindow.currentFolder()` and follows the window with an AXObserver. ↩ goes by the same rules as a pasted path.

## Writing pad

- `WritingAssistant` opens the pad over the focused window of the frontmost app and remembers that window.
- `ScreenText` captures that one window with ScreenCaptureKit and reads its text with Vision. This needs the Screen Recording permission; without it the pad still fixes text, just without the screen as context.
- `TextFixer` sends the draft, with the end of the screen text as context, to Apple's on-device model (FoundationModels). Nothing leaves the Mac. Fixing needs Apple Intelligence turned on.
- `WritingPadKeys` takes ⌘⇧Space in the keyboard tap, ahead of Siri's own watcher, which ignores ⇧ and would otherwise read a held ⌘⇧Space as its "hold ⌘Space". The Carbon hotkey stays as the fallback when the tap isn't running.
- `WritingPad` is a non-activating panel, so the app being replied in stays frontmost and keeps its cursor. `Paster` pastes with ⌘V into that app, and only that app. The sent text stays on the clipboard.
- `ReplyStore` appends every sent reply to `~/Library/Application Support/Screen Tools/Replies/<year>-<month>.jsonl`, one JSON object per line: `date`, `app`, `bundleID`, `screen` (the window's text), `typed`, `sent`. The folder is readable only by you.
- The log records that a reply was sent and its length, never its text or the screen's.

## License

MIT. See [LICENSE](LICENSE).
