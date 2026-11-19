# Changelog

## 1.34.0
- **⌃⌘←/→ switches desktops, like Win+Ctrl+←/→ on Windows.** It goes to the desktop on the left or right, full-screen apps included, one per press, at once rather than sliding; at either end it does nothing. macOS 27 ignores its own ⌃←/→ when an app presses it, so RubberMAC sends the Dock a trackpad swipe instead (the way InstantSpaceSwitcher does), and never one past the last desktop, which on macOS 27 leaves the screen black for a while. Remote desktops and VMs keep the keys. On by default; a switch on the Keyboard page turns it off.

## 1.33.3
- **Fixed: the login window is named as one even on the first check.** 1.33.2 kept the name from the check before, but if macOS's list of running apps missed the login window right as Secure Input came on, the card started out blaming a background process for 3 seconds. RubberMAC now asks the kernel what the process is when that list has no entry for it, and the log no longer repeats "a login window" when the list catches up.

## 1.33.2
- **Fixed: the Secure Input card no longer flickers to "a background process"** while the login window holds Secure Input. For a single check at a time, macOS's list of running apps sometimes didn't include the login window. For those 3 seconds the card and the icon's tooltip said a background process had Secure Input on and suggested quitting an app, and the log said the holder had changed and then changed back. The same process now keeps the name it was already known by.

## 1.33.1
- **The "!" on the menu-bar icon explains itself:** hovering over the icon while Secure Input hides the keys shows the same words as the Secure Input Is On card: who has it on, what stops working, and how to get the keys back.

## 1.33.0
- **RubberMAC tells you when an app's Secure Input hides the keys, and which app.** While an app has Secure Input on, macOS hides the keys pressed with ⌘, Ctrl or Alt from RubberMAC, so window snapping, ⌘R, Ctrl-C/V and Alt-Tab stop working with no sign why. Now the menu-bar icon gets an orange "!", and a **Secure Input Is On** card at the top of the General and Keyboard pages names the app and says how to get the keys back, with a **Show** button that brings the app to the front. Both go away once Secure Input is off. The log says it once when it comes on and once when it goes off, instead of a line for every ⌘ press.
- **Spotlight can search only apps.** **Spotlight Searches Only Apps**, on the Keyboard page, does what ⌘1 does in Spotlight's search bar (the tip from the MacRumors thread "Spotlight: anyone able to hide certain results?"), every time the bar opens: results are apps and nothing else, and the empty field reads "Applications". Esc goes back to searching everything, and the next time Spotlight opens it shows only apps again. Letters typed straight after the shortcut are kept: Spotlight would wipe the ones that reach it while it switches to apps, so RubberMAC holds them for that moment and passes them on in order. While another app holds Secure Input, macOS hides keys from RubberMAC and a very quick first letter can still be lost. Off until you turn it on.
- **Fixed: ⌘ + wheel zoom works in an app that has just opened or relaunched,** like Claude after an update: its menus can't be read for a moment after it opens, and that was taken as the app having no zoom for the next half minute. It's now tried again every second until they can be read.
- **Fixed: ⌘ + wheel zooms Claude in and out.** It typed the app's Zoom In and Zoom Out shortcuts, which Claude ignored: ⌘⇧= did nothing there and ⌘- didn't zoom out. It now presses the menu items themselves through Accessibility, as choosing them from the View menu does, one at a time and in order without ever holding up the mouse. An app that stops answering gets no presses saved up for when it wakes, and when an app builds its menus anew, as Claude does every so often, the item is found again.

## 1.32.1
- Repo only, no change to the app: `downloads.sh` shows how often each release has been downloaded, and a daily **Download Counts** workflow keeps that history on the `stats` branch, since GitHub keeps only running totals.

## 1.32.0
More ideas from MacRumors forum threads.
- **A mouse wheel that works like Windows.** The wheel can scroll the classic way while the trackpad stays natural, every notch can scroll the same 3 lines however fast you turn it (Logi Options+ mice too), and ⌘ + wheel zooms Google Chrome, Claude and other apps in and out like Ctrl + wheel, without ⌘'s release opening Start; three switches on the Mouse page, the first two off until you turn them on.
- **Bring lost windows back, or make an app forget its window sizes.** **Bring Windows Back Onto the Screens**, in a new Lost Windows section of the Windows page, moves windows that are mostly off the screens or too big for theirs back on, and **Forget an App's Window Sizes…** quits the app you pick, deletes the window frames it saved, puts its saved windows in the Trash and opens it again: what the Terminal fixes in the MacRumors thread do, in one click.
- **New windows open on the screen you're using.** **Open Apps and Files on the Screen You're Using**, in the new New Windows section of the Windows page, moves a window that opens on another screen right after you open an app or a file to the screen with the pointer, and **Always Open an App on One Screen** gives an app a screen for all its new windows.
- **Pick the resolution really sent to each screen, as on Windows.** The Brightness page's new Resolution card lists each screen's real resolutions and refresh rates (not just "Looks like" sizes), and after a change asks "Keep this resolution?" on every screen, going back by itself after 15 seconds.
- **Fixed: holding ⌘ while scrolling, then letting go, no longer opens Start** with mice whose software posts the wheel's scrolls itself, like Logi Options+.

## 1.31.0
Ideas from MacRumors forum threads.
- **⌘ on its own opens RubberMAC's own Start, in your order, with folders and pins.** Spotlight's Apps view sorts itself and has no folders, pins or right-click. Start lists the same apps and keeps them how you arrange them: type to search straight away and press ↩, drag icons into place, drop one app onto another to make a folder and name it, right-click to pin an app to the top row, show it in Finder or move it to the Trash after a question that names it. New apps join at the end. The app you were in stays in front. Turn it off with **⌘ Alone Opens RubberMAC's Start, Not Spotlight's Apps** on the Keyboard page.
- **Volume and brightness show on the screen you're changing.** macOS 27.2 shows the level under the menu-bar icon, on one screen. RubberMAC now changes the volume with the volume keys itself, in 16 steps (quarter steps with ⌥⇧), and shows it low on the screen under the pointer. The panel fades a moment after the last press, takes no clicks and shows over full-screen apps. The brightness keys now work on external screens too, through the same DDC or software dimming as the sliders, and ⌃⌥⌘↑/↓ show the level as well. The built-in screen, Apple's own displays and others macOS sets itself (like LG's UltraFine) keep macOS's brightness keys, and a device whose volume can't be set, like a TV on HDMI, keeps macOS's volume keys. **Show Volume and Brightness on the Screen You're Changing**, on the Brightness page, gives every key back to macOS.
- **Dim or blur the windows behind the one you're using.** **Background Windows**, on the Windows page, darkens or blurs everything behind the window in front, on every screen and the desktop too, so the window you're working in stands out; a Strength slider sets how much. The menu bar, the Dock, the window's own sheets, its app's floating panels and RubberMAC's own panels stay clear. Clicks go through to whatever is underneath, so clicking a dimmed window brings it forward and the effect moves with it, as it does when you switch apps, minimize or close a window. A full-screen app, or the desktop with nothing in front, is left as it is. It's off until you choose Dim or Blur.
- **Each app keeps its own language, and search opens in English.** Switch to Hebrew in one app and English in another, with Alt-Shift, the menu bar or ⌃Space, and each app is in its own language again when you go back to it; an app you haven't switched in yet keeps the language that's on. Spotlight, opened with ⌘Space, ⌘R or a ⌘ tap, and the Start menu open in English, and closing the search without picking an app puts the app's language back; an app opened from the search gets its own. **Each App Keeps Its Own Language** and **Spotlight and Start Open in English**, under **Left Alt-Shift Switches Language** on the Keyboard page, turn them off.
- **Keep the Dock on the screen you choose.** With two or more screens, the Dock jumps to whichever screen's edge the pointer pushes against. **Keep the Dock On**, in the Dock section of the Windows page, picks a screen for it: on the others, pushing against the Dock's edge no longer brings it over. If the Dock is elsewhere when you choose, or after screens connect, RubberMAC brings it to your screen, moving the pointer there for a moment and back. It follows the Dock's side and auto-hide, and **Bring Up the Dock in Full-Screen Apps** still works on the chosen screen. An unplugged screen shows as "(not connected)", and the Dock is left to macOS until it's back. With "Displays have separate Spaces" off, the Dock stays on the main screen and the page says so.
- **Send a feature request from the app, no account needed.** **Send a Feature Request…**, in a new Ideas section on the General page, opens a small window: write what you'd like RubberMAC to do, up to 2,000 characters, and add your email if you'd like a reply. It goes to RubberMAC's developer with your RubberMAC and macOS versions and nothing else. If it can't be sent, the window says why and keeps what you wrote.

## 1.30.0
- **⌘↑ twice maximizes.** Press ⌘↑ again on the window it just moved and the window is maximized, wherever the first press put it: from a bottom quarter, ⌘↑ goes to the half and the next ⌘↑ maximizes rather than stopping at the top quarter, and an app that can't be made as short as a quarter is maximized instead of being asked for the quarter every time. With a camera marked in front of the screen, the first ⌘↑ maximizes clear of it as before and the second fills the whole screen, camera spot too. Move the window or press another arrow in between and ⌘↑ steps through the panes as before.
- **⌘R opens Spotlight, like Win+R on a PC.** It brings up the Search or Ask bar the way ⌘Space does, by pressing Spotlight's own shortcut: if you changed that shortcut, ⌘R follows it, and if you turned it off, ⌘R is left to the app. It takes ⌘R from every app but remote desktops and VMs, so ⌘R no longer reloads a web page or replies in Mail; turn it off with **⌘R Opens Spotlight, Like Win+R** on the Keyboard page.
- **⌘ on its own opens Spotlight's Apps, like the Windows key opens Start.** Press ⌘ and let go without pressing anything else, and the grid of your apps comes up. Either ⌘ key works. A ⌘ shortcut, a ⌘-click, a ⌘-scroll or ⌘ with another modifier doesn't count, and remote desktops and VMs keep the key. While Secure Input is on (a password field, or a login window that kept it after waking), the keys pressed with ⌘ are hidden, so a ⌘ tap does nothing then rather than mistake ⌘← for ⌘ alone; the log says so. **⌘ Alone Opens Apps, Like the Windows Key** on the Keyboard page turns it off.

## 1.29.0
- **Use Atkinson Hyperlegible in your apps, by their icons.** Under the font switch on the Writing page, **Use It In** shows an icon for each app whose text RubberMAC can set in the font: the Writing Pad, TextEdit, Mail, Terminal, Chrome and Firefox, whichever you have. Click one to switch it on: its icon is in full colour with a check, and faded while it's off. Point at an icon to see what changes there. Sizes stay what each app had, and switching an app off puts back exactly the font it had before.
  - **TextEdit:** new documents, in Next for rich text and Mono for plain text, once TextEdit is opened again.
  - **Mail:** messages and the message list in Next, fixed-width text in Mono, once Mail is opened again.
  - **Terminal:** its default profile in Mono, open windows included, straight away; macOS asks once whether RubberMAC may control Terminal.
  - **Chrome and Firefox:** web pages that don't choose their own font, in every profile. They keep their settings in memory while they run, so a click while one is open waits, and the change is made the moment you quit it.
  - Safari isn't offered: it doesn't let web pages use fonts you install yourself.
- **Atkinson Hyperlegible Mono comes with the app too**, the monospaced sibling of Next, for Terminal and other fixed-width text: in a terminal every letter gets the same width, which leaves gaps around the narrow letters of Next. If you turned the font on in 1.28.0, Mono is added beside it when RubberMAC starts.
- **The font switch says what it does:** **Put Atkinson Hyperlegible in Every App's Font List**. It makes the font available to pick in every app; it doesn't change any text by itself. The icons above are what change it.
- **The Writing Pad can write in Atkinson Hyperlegible Next**, both what you type and the fixed version.

## 1.28.0
- **Atkinson Hyperlegible Next comes with RubberMAC.** The Braille Institute's typeface for easy reading is inside the app, all 14 faces from ExtraLight to ExtraBold with their italics. **Add Atkinson Hyperlegible Next to Every App**, on the Writing page, puts it in every app's font list, the way Font Book's Install does, and turning it off takes it out again. It never overwrites or removes a font file that isn't its own copy, and if you've already installed the font another way the page says so instead of adding a second copy. macOS's own menus and windows keep their font: that font is on the sealed system volume, and no app can change it.

## 1.27.0
- **⌘L locks the screen, like Win+L on a PC.** It locks at once, the same way as Lock Screen in the Apple menu, from any app. It takes ⌘L from every app, so ⌘L no longer jumps to a browser's address bar (click the bar instead); turn it off with **⌘L Locks the Screen, Like Win+L** on the Keyboard page.

## 1.26.0
- **The Eye Color Camera is built in: no Python, no camrelay.** RubberMAC now reads the camera, finds your irises with Apple's Vision framework, recolours them and sends the picture to OBS Virtual Camera itself. All it needs is OBS installed, with Start Virtual Camera clicked in it once; OBS needn't be running. Your colour, strength and camera carry over from camrelay. Calibrate… is gone: the live preview and the colour circles on the page do its job.
- **Pick the eye colour in one click.** The Eye Color Camera page shows its colours as a row of circles, like the accent colours in System Settings, instead of a menu of names: the chosen one is ringed, and the name of the chosen one (or the one under the pointer) shows under **Colour**. The row sits right under the switch, above the preview, so the effect shows just below. Searching for a colour's name, like "hazel", finds it; VoiceOver reads each circle by name.

## 1.25.0
- **Real eye colours for the Eye Color Camera.** The colours are now natural eye tones instead of crayon colours: Blue, Ice Blue, Deep Blue, Blue Green, Green, Gray, Hazel, Amber and Brown. Real irises are muted, so the old bright blue looked painted on. Each tone is set by published iris measurements where they exist (ice blue, hazel, brown) and estimated from them otherwise, with famous eyes as a reference: Paul Newman's ice blue, Elizabeth Taylor's deep blue, Tyra Banks's hazel. They need camrelay 0.2; a colour chosen before (Light Blue, Violet) carries over to the nearest tone.
- **The colour dot on the menu-bar icon has a ring**, so a dark brown dot shows on a dark menu bar and a pale blue one on a light menu bar.

## 1.24.0
- **A preview on the Eye Color Camera page.** While it's on and the page is open, the page shows what others see on the call: the picture from OBS Virtual Camera, with your eyes recoloured and not mirrored, so a change of colour or strength shows straight away. It reads only the virtual camera, never your real one, and stops when you leave the page. The first time, **See What Others See** lets macOS ask for the camera permission.

## 1.23.0
- **A settings panel instead of the long menu.** Clicking the menu-bar icon now drops down a panel like System Settings: pages in a sidebar (General, Screen Saver, Brightness, Windows, Keyboard, Writing, Eye Color Camera, Mouse, Window Layouts, Permissions), and that page's settings as cards on the right, with switches, popups and buttons. Everything the menu did is on a page, and Quit RubberMAC is at the bottom of the sidebar.
- **Search.** ⌘F and type: the sidebar keeps the pages with a match and each page shows only the settings that match. ↑/↓ move between pages, Esc and ⌘W close it, and it opens on the page you last looked at.
- **A Permissions page.** It says whether Accessibility, Screen Recording and control of Finder are on, what each is for and what's lost without it, with a **Turn On…** button for the ones that are off. **Check Again** reads them afresh and restarts what was waiting for them, and a dot on the page in the sidebar says when Accessibility is needed. Reading a permission never asks for it.
- **Delete in Finder moves the highlighted file to the Trash**, as on a PC, with either delete key; ⌘Z puts it back. Renaming, search, the address bar and the writing pad keep their delete key. **Delete Moves the Highlighted File to the Trash** on the Keyboard page turns it off.
- **Needs macOS 27 or later, on a Mac with Apple silicon.** Earlier versions said macOS 14, but the builds are marked for macOS 27 and made for Apple silicon only; the app now says so, so an older Mac is told before it opens.
- **The Eye Color Camera is a page in the panel**, with its colour, strength and camera as popups and the camera's state under its switch, kept up to date while the page is open.

## 1.22.0
- **Eye Color Camera.** A new section in the menu recolours your eyes live on video calls, brown to blue or any colour, with [camrelay](https://github.com/gitayg/camrelay). RubberMAC runs camrelay as a helper and sends its picture to the OBS virtual camera: turn it on, then choose **OBS Virtual Camera** in Zoom, Meet or Teams. Colour, strength and the camera (listed by name) are in the menu, **Calibrate…** opens camrelay's guided calibration, and **Turn On When RubberMAC Starts** has it ready at login. It needs camrelay and OBS installed; until then the menu offers **Set Up camrelay…**. The first time it's turned on, macOS asks to let RubberMAC use the camera.
- **The menu-bar icon shows the eye colour.** While the Eye Color Camera is on, a dot in the colour you chose sits in the corner of RubberMAC's icon, so you can see at a glance that your eyes are being recoloured, and in which colour.

## 1.21.0
- **RubberMAC says why before it asks for a permission.** A short message explains what Accessibility and Screen Recording are for and what happens without them, with **Not Now** beside **Continue**, before macOS shows its own prompt.
- **It asks for Screen Recording by itself, once.** Right after Accessibility is allowed, or at launch if it already is, so window pictures no longer depend on finding the menu item. The menu still offers it afterwards.

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
