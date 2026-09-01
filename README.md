<p align="center">
  <img src="docs/assets/hero.svg" alt="Pelmet — a calm menu bar for macOS" width="800">
</p>

<p align="center">
  <a href="https://pelmet.fif7y.com"><img src="https://img.shields.io/badge/website-pelmet.fif7y.com-6841ED" alt="Website: pelmet.fif7y.com"></a>
  <a href="https://github.com/fif7y/pelmet/releases/latest"><img src="https://img.shields.io/github/v/release/fif7y/pelmet?label=download&color=2ea44f" alt="Download latest release"></a>
  <a href="#install"><img src="https://img.shields.io/badge/requirements-macOS_27%2B-E8A33D" alt="Requires macOS 27 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/fif7y/pelmet" alt="License: GPL-3.0"></a>
  <a href="https://github.com/sponsors/fif7y"><img src="https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa" alt="Sponsor Pelmet"></a>
</p>

Pelmet hides the icons you don't need until you do — hover, click, or press a
shortcut and they slide back in. It's built natively on macOS 27's new menu
bar architecture instead of the window-juggling tricks older managers rely
on, which is why hiding feels like part of the system: no overlay windows, no
fake bars, no icons jumping when the bar reflows.

<p align="center">
  <img src="docs/assets/bar-anim.svg" alt="The menu bar: hidden icons tuck away behind the chevron, then return on hover" width="575"><br>
  <sub>Collapsed, and a hover later.</sub>
</p>

## Choose what stays

Three sections, one rule: **Visible** is always there, **Hidden** comes back
on a hover or a click, and **Always Hidden** only appears when you ask for it
(double-click or ⌥-click the chevron). Arrange them in the layout editor —
real app-icon previews, drag-and-drop ordering — or skip the window entirely
and ⌘-drag icons across the chevron right in the menu bar; Pelmet adopts the
move either way.

<p align="center">
  <img src="docs/assets/editor-anim.svg" alt="The layout editor: dragging an icon from Always Hidden to Hidden, both sections reflowing" width="640"><br>
  <sub>The layout editor — drag icons between Visible, Hidden and Always&nbsp;Hidden.</sub>
</p>

System icons hide too — Sound, Battery, Wi-Fi and friends behave like any
other icon. The few macOS protects (Clock, Control Center, Siri) are shown
locked in the editor, not pretended away, and anything macOS groups together
gets an honest badge instead of a fake handle.

## Reveal on your terms

Every way back in is a setting: hover (with an adjustable delay), a click on
empty menu bar space, a double-click for the always-hidden section, or the
chevron itself. Pick how it looks — **Instant**, **Smooth**, or **Fade** —
and how it ends: auto-rehide after a delay you set, or the moment you click
somewhere else.

<p align="center">
  <img src="docs/assets/screenshot-settings.png" alt="General settings: reveal on hover with delay, click and double-click reveals, Instant/Smooth/Fade animation, auto-rehide rules" width="640"><br>
  <sub>Your rules for revealing — and for putting everything back.</sub>
</p>

## And the rest

- **Per-display behavior** — set a display to always show everything or to
  collapse; whichever display your pointer is on wins.
- **Built-in replacements** — media controls, AirDrop, camera/mic indicator,
  and Shortcuts items that survive hiding, since macOS temporarily removes
  its own extras while hiding is active.
- **Separators** — visual dividers that behave like icons, with adjustable
  opacity, ⌘-draggable anywhere in the bar.
- **Signed updates** — Sparkle with EdDSA signatures, checked against a
  signed appcast.

## How it works

macOS 27's menu bar can hide items natively — it's the mechanism behind the
system's assessment (exam lockdown) mode. Pelmet drives that mechanism directly:
it asserts a configuration listing what should stay visible, and macOS itself
hides the rest and reflows the bar. That's why hiding feels like part of the
system — it *is* the system.

The catch: this API lives in a **private Apple framework**
(`MenuBarClientCore`). It isn't documented or guaranteed, so a macOS update
could change or remove it. Pelmet resolves it at runtime and fails soft — if the
API ever disappears, Pelmet simply reports hiding as unavailable rather than
breaking your menu bar. Everything else (item positions, clicks, previews)
uses public APIs: Accessibility and ScreenCaptureKit.

## Install

Download the latest DMG from [Releases](https://github.com/fif7y/pelmet/releases),
drag Pelmet to Applications, and launch it. Or with Homebrew:

```sh
brew install fif7y/tap/pelmet
```

Requires **macOS 27 (Golden Gate)**. Earlier versions of macOS use a
different menu bar architecture that Pelmet does not target.

On first launch Pelmet asks for one permission:

- **Accessibility** (required) — how Pelmet sees the menu bar's items and
  positions, and how clicking a hidden item works without revealing
  everything.

Screen Recording is optional and never prompted for during onboarding — if
granted, Pelmet uses it to paint seamless cover strips over the bar while
items swap during reveals and reorders; without it, transitions simply run
uncovered.

Pelmet is notarized by Apple and ships with the hardened runtime. It is not
sandboxed — managing the menu bar requires APIs the App Store sandbox
forbids.

More in the [FAQ](docs/FAQ.md).

## Build from source

Requires Xcode with the macOS 27 SDK and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/fif7y/pelmet.git
cd pelmet
xcodegen
xcodebuild -project Pelmet.xcodeproj -scheme Pelmet -configuration Release build
```

The engine logic lives in two local Swift packages — `Packages/PelmetCore`
(section model, rehide state machine) and `Packages/PelmetEngine` (menu bar
convergence) — each with its own test suite:

```sh
swift test --package-path Packages/PelmetCore
swift test --package-path Packages/PelmetEngine
```

## Licenses & acknowledgements

Pelmet was inspired by [Ice](https://github.com/jordanbaird/Ice), the open-source
menu bar manager for earlier versions of macOS — Pelmet picks up where Ice left
off, rebuilt from scratch for macOS 27's new menu bar architecture (no code is
shared between the projects).

Pelmet's only third-party dependency is
[Sparkle](https://github.com/sparkle-project/Sparkle) (in-app updates), used
under the [MIT-style Sparkle license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).
Everything else is custom code on top of Apple's system frameworks.

## License

© 2026 Gabriel Faucon. Licensed under the
[GNU General Public License v3.0](LICENSE) — use, study, and fork freely;
distributed derivatives must remain open under the same license.

Pelmet is an independent project, not affiliated with or endorsed by Apple Inc.
Apple, macOS, and the Mac are trademarks of Apple Inc.
