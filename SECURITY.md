# Security Policy

Pelmet runs with Accessibility access and, if you grant it, Screen Recording.
That's a lot of trust for a menu bar app, so here's what it does with it and
how to reach me if something looks wrong.

## Reporting a vulnerability

Please don't open a public issue for anything security related. Use GitHub's
private reporting instead:

**[Report a vulnerability](https://github.com/fif7y/pelmet/security/advisories/new)**

It goes straight to me and stays private until there's a fix. Include what you
found, how to reproduce it, the Pelmet version (Settings › About) and your
macOS build. A `pelmet.log` excerpt helps (`~/Library/Logs/Pelmet/`).

Pelmet is a one-person project, so no SLA, but I'll acknowledge within a few
days and keep you posted in the advisory. Fixes ship as a regular release,
Sparkle offers them to every install, and you get credit in the release notes
unless you'd rather not.

## Supported versions

Only the [latest release](https://github.com/fif7y/pelmet/releases/latest)
gets fixes. Pelmet updates itself, so staying current is the whole story.
Requires macOS 27.

## What Pelmet does with your Mac

- **Accessibility** is how Pelmet reads the menu bar (which items exist, where
  they sit) and clicks a hidden item for you. It doesn't look at other windows
  and it doesn't watch the keyboard.
- **Screen Recording** is optional. The animation styles use it to take two
  stills of the menu bar (one per transition). Nothing is written to disk and
  nothing leaves the Mac.
- **Hiding** goes through the mechanism macOS uses for its own assessment mode,
  a private framework Pelmet resolves at runtime. If Apple changes it, Pelmet
  reports hiding as unavailable rather than doing something else. It's a
  compatibility risk more than a security one (the
  [README](README.md#how-it-works) covers it).
- **Network.** Two calls, both to hosts you can check. Sparkle fetches the
  appcast from `fif7y.github.io/pelmet` and downloads updates from GitHub
  Releases. The Thanks pane fetches the star count from the public GitHub API
  (no token). No telemetry, no crash reporting, no account.
- **On disk.** Your layout and settings live in Pelmet's own preferences
  domain (`app.fif7y.Pelmet`) and a log in `~/Library/Logs/Pelmet/`. The log
  holds item identifiers and positions. Window contents and keystrokes never
  make it in there.

## Verifying a download

Every DMG is signed with a Developer ID certificate and notarized by Apple,
and the app runs with the hardened runtime. On any copy of Pelmet:

```sh
spctl -a -vv /Applications/Pelmet.app
```

should print

```
source=Notarized Developer ID
origin=Developer ID Application: GABRIEL FAUCON (YW9UY68SQ7)
```

Updates are signed with an EdDSA key whose public half is baked into the app.
Sparkle refuses anything the appcast can't vouch for.

Pelmet isn't sandboxed. Managing the menu bar needs APIs the App Store
sandbox forbids, and the README says so up front.

## Out of scope

- Hiding stops working after a macOS update. Report it as a bug, it's expected
  to happen at some point, and it's on me to keep up.
- Anything that needs Accessibility or root already granted to the attacker.
- A managed app misbehaving in the menu bar.
