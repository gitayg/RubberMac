# Changelog

## 1.20.0
- **A new app ID, `app.rubbermac.RubberMAC`.** macOS sees this as a new app, so Accessibility and Screen Recording have to be allowed once more, and an earlier copy doesn't update itself to this version: install it from the DMG.
- **Updates come from this repo's releases**, which hold a zip for the updater and a DMG for installing by hand.
- **An update is checked against the running copy's own signature**, as strictly as before, instead of against a developer named in the code.

## 1.19.2
- **Windows that ask not to be captured stay that way.** The window-server picture added in 1.19.1 is now used only for a window macOS's screen capture lists but can't take because it's off screen, and never for a window whose app asked not to be captured.

## 1.19.1
- **Full-screen windows have their picture in Alt-Tab and the Dock menu.** A window in full screen on a Space that isn't showing appeared without a picture, only its place on the screen. macOS's screen capture takes no picture of such a window, so RubberMAC now asks the window server for it instead.

## 1.19.0
- **Screen Tools is now RubberMAC.** Same app, new name: in the menu bar, its menu and messages, and the app's file name. Settings, permissions and updates carry over, since the app's identity underneath stays the same.

## 1.18.0
- **Pick a window from the Dock.** Clicking the Dock icon of an app with two or more windows no longer brings all of them forward: a menu opens beside the icon with a picture and the title of each window, and clicking one goes to just that window, even when it's minimized, hidden or on another desktop. Esc, a click elsewhere or another click on the icon closes the menu. Apps with one window, modifier-clicks, right-clicks and dragging icons work as before. **Click an App in the Dock to Pick Its Window** in the menu turns it off.
- **See how busy each copy of an app is.** Under each window's title in the Dock menu, a line shows its app's CPU and memory, counting the helper processes and anything else it started, updated every second. When several copies of an app run from the same place, each with its own `--user-data-dir` (as with separate Claude accounts), the line also names the copy (`Teams · CPU 12% · 1.2 GB`), so their windows can be told apart.

## 1.17.0
- **Alt-Tab lists the windows on every desktop and in full-screen apps.** Windows on other Spaces, and windows of hidden apps, now show in the switcher; picking one switches to its Space. Before, only the current desktop's windows were listed.
- **The switcher fits every window on the screen.** The tiles shrink to fit however many windows are open, on up to 96% of the screen, instead of scrolling once they got small.
- **⌘⇧Space no longer brings up Siri.** Siri ignores ⇧, so holding ⌘⇧Space a moment counted as its "hold ⌘Space" and brought up Siri, or "Siri Unavailable", over the pad. Screen Tools now takes the key before Siri sees it.
- **The Dock comes up in full-screen apps.** In a full-screen app macOS shows the Dock only after a firm push against the edge of the screen. With **Bring Up the Dock in Full-Screen Apps** on, moving the pointer to the edge is enough.
- **An address bar in Finder windows.** A field under the toolbar of the front Finder window shows the folder's path; paste or type a path there and press ↩ to go to it. It needs the same one-time OK to control Finder as pasting a path.

## 1.16.1
- **Click a window in Alt-Tab to switch to it.** While the switcher is open, clicking any window's tile switches to that window.
- **The switcher says how to get window pictures.** Without Screen Recording, a line under the tiles says where to allow it, instead of showing only app icons with no explanation.

## 1.16.0
- **Alt-Tab shows the windows themselves, big.** The switcher is now a grid of window pictures that uses most of the screen, as on Windows: the fewer windows you have open, the bigger they are. Under each are the app icon, the title and a small map of where the window is. Pictures need Screen Recording (**Show Window Pictures in the Switcher…** in the menu); until then each tile shows where the window is, with its app icon.

## 1.15.1
- **The switcher shows where each window is.** Each window's picture sits at its place on a small map of your screens, so you can tell the Teams window on the left half from the one in the corner. The place shows even without Screen Recording, with the app icon in it; minimized windows are shown faded where they'll come back.

## 1.15.0
- **Window pictures in the switcher.** Alt-Tab (and ⌘Tab) shows a small picture of each window next to its title, so windows of the same app, like three Teams windows, are easy to tell apart. The list opens right away with the pictures from last time and updates them as fresh ones come in. Pictures need Screen Recording: choose **Show Window Pictures in the Switcher…** in the menu and turn on Screen Tools in System Settings. They're kept in memory only.
- **The switcher remembers what you used across restarts.** Windows are listed in the order you last used them, and that order now survives Screen Tools restarting (as it does after each update) instead of starting over. It starts over after the Mac restarts.

## 1.14.1
- **Typing no longer waits for Screen Tools.** Keys went through Screen Tools on the same thread as its other work, so while it saved window layouts (every 30 seconds or so) or waited on a slow app, what you typed could hang for a third of a second. The keyboard now has a thread of its own.

## 1.14.0
- **Paste a path in Finder to go there.** With a folder's path on the clipboard, ⌘V (or Ctrl-V) in a Finder window goes to that folder in the same window, no ⌘⇧G needed. A file's path goes to its folder and selects the file. Plain paths, `~`, `file://` links, quoted paths and paths copied from a terminal all work. Pasting into a text box (renaming, search) and pasting copied files work as before. The first time, macOS asks to let Screen Tools control Finder.
- **⌘Tab switches windows too.** With Alt-Tab set to switch windows, ⌘Tab now opens the same window switcher, so each of an app's windows can be picked, such as three Teams windows. Turn off **⌘Tab Switches Windows Too** to get the macOS app switcher back.
- **Logs keys that had to wait.** A key that waited more than 50 ms for Screen Tools' keyboard handling is logged with how long it waited, to track down typing lag.

## 1.13.0
- **Writing pad: ⌘⇧Space fixes what you write in Teams, Outlook or any app.** Press it with the cursor in a message box and write your reply in the pad that opens. Apple's on-device model fixes spelling, grammar and punctuation as you type, and the changed words are highlighted. **↩** pastes the fixed text where you were typing and leaves it on the clipboard, **⌥↩** pastes it as typed, **⇧↩** starts a new line, and **Esc** closes the pad and keeps the draft. Nothing you write leaves the Mac.
- **Your replies are saved with what they answered.** With Screen Recording allowed, the pad reads the window you're replying to, which helps it spell names right. Every reply is saved with that text in **Open Saved Replies**.

## 1.12.0
- **Alt-Tab goes back to the window you were in.** It now follows the order windows had focus, not the order they're stacked on screen. Switching into an app with several windows raises all of them, so Alt-Tab used to pick another of that app's windows instead of the one you came from. With the desktop focused, Alt-Tab goes to the window you used last.
- **Keep windows clear of a camera in front of the screen.** Choose **Mark Where the Camera Is…** and drag a box around the camera and its stand on the screen it stands in front of. With **Keep Windows Clear of the Camera** on, ⌘-arrow snapping fits windows around it: maximize fills the screen above it, and halves and grid panes stop beside it. Turn the toggle off when the camera isn't there; the marked spot is remembered.

## 1.11.0
- **Updates itself.** Screen Tools checks for a new version when it starts and every six hours, installs it and relaunches. It only installs a build signed by Screen Tools' developer. Turn off **Install Updates Automatically** to choose when; **Check for Updates** checks now.
- **Pointer and wheel speed are remembered per mouse model.** Each mouse keeps its own pointer speed, even with two connected at once, and gets it back whenever it reconnects. The wheel speed follows the mouse in use; with several connected, it's the one connected last. Keyboards with a built-in pointer, like the MX Keys, are left alone.

## 1.10.0
- **Mouse section:** pointer speed up to 16 (System Settings stops at 3), and wheel speed from ×0.5 to ×8. The wheel speed applies to mouse wheels only; trackpad and Magic Mouse scrolling are unchanged.
- **Hold the wheel and move to scroll**, along one direction at a time, faster the further you move. A quick wheel click is still a middle click. Off in remote desktops.

## 1.9.0
- **Choose the snapping grid:** 2–4 columns × 1–3 rows (default 2 × 2). ⌘-arrow snapping steps through those panes.
