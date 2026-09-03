# Pelmet FAQ

**Which macOS versions does Pelmet support?**
macOS 27 (“Golden Gate”) only. Pelmet is built natively on macOS 27’s new menu
bar architecture rather than the window-juggling tricks older managers use —
that’s why it’s smooth, and why it can’t run on macOS 26 or earlier.

**Why do some icons hide or move together?**
macOS hides items per *app*, not per icon. If an app puts several icons in the
menu bar, they share one visibility setting — the layout editor shows these as
a grouped “moves together” badge.

**An icon I didn’t hide disappeared (AirDrop, Focus, fast user switching).**
While hiding is active, macOS itself temporarily removes a few of its own
extras. Pelmet can’t exempt them individually; they come back the moment hiding
is off. Pelmet ships its own replacements for the common ones (media controls,
AirDrop, camera/mic indicator, Shortcuts) — add them in Settings → Menu Bar.

**Clicking the clock flashes the hidden icons for a moment.**
That's Pelmet working around macOS: while any icon is hidden, the system
refuses the clock's click to open Notification Center (the same lockdown exam
mode relies on), and nothing else can open it from outside. So Pelmet lets
everything show for the blink it takes the click to land, then hides again.
Turn it off in Settings → Menu Bar → Notification Center if you'd rather use
the two-finger swipe from the right edge of the trackpad, which always works.

**Why does Pelmet ask for Accessibility?**
It’s how Pelmet sees the menu bar’s items and their positions, and how clicking
a hidden item works without revealing everything. Required.

**Why does Pelmet ask for Screen Recording? Do I need it?**
Only for live icon previews in the layout editor. It’s optional — without it
the editor shows app icons instead. macOS re-confirms Screen Recording roughly
monthly for all apps; if the nag bothers you, turn the permission off and keep
using app icons.

**Some system icons can’t be hidden.**
macOS protects a small set of system items (Clock, Control Center, Siri). Pelmet
shows them locked in the editor rather than pretending.

**Can I have different layouts on each display?**
macOS mirrors the same items on every display, so layouts are global. What
*is* per-display is behavior: set a display to “always show” or “collapse”,
and whichever display your pointer is on wins.

**Does Pelmet use private APIs?**
One, deliberately: the hide/show mechanism itself. macOS 27 can hide menu bar
items natively (it's how the system's assessment/exam mode works), but the API
lives in a private framework (`MenuBarClientCore`) with no public equivalent.
Pelmet resolves it at runtime and fails soft — if a macOS update changes or
removes it, Pelmet reports hiding as unavailable instead of misbehaving, and
macOS restores the bar on its own (the hide assertion is process-bound).
Everything else uses public APIs. This is also why Pelmet can't be on the App
Store.

**Could a macOS update break Pelmet?**
It could — see above. The failure mode is graceful (icons just stay visible),
and updates ship through Sparkle, so a fix arrives without you doing anything.

**Is Pelmet sandboxed?**
No — managing the menu bar requires APIs the App Store sandbox forbids. Pelmet
is notarized by Apple, ships with the hardened runtime, and updates are signed
(Sparkle, EdDSA).

**How do updates work?**
Pelmet checks a signed appcast and offers updates in-app (Sparkle). You can
check manually in Settings → About.

**How do I open Settings if I turned the Pelmet icon off?**
Any of: the global shortcut (⌥⌘, by default), right-click a Pelmet separator,
right-click empty menu bar space, or launch Pelmet again from Finder/Spotlight.

**I'm developing an app in Xcode and its menu bar icon disappears while Pelmet runs.**
A macOS limitation, not a setting: the system's menu-bar hiding mechanism
matches apps by their LaunchServices registration, and apps running out of
Xcode's DerivedData never match — so they get hidden no matter which section
they're in. Run your development build from /Applications (copy it there, or
archive-export), or quit Pelmet while iterating. Everything behaves normally
for the same app once it runs from a stable location.
