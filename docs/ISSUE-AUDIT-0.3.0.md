# Issue audit against the sets build (branch `roster`, 2026-09-21)

Question: does every issue Pelmet has closed or left open still hold on
0.3.0 (sets core, `docs/CORE-SETS.md`), before `roster` merges to main?
Method: each issue's fix mechanism mapped to the M3 survive/delete map, then
checked against today's log on Gab's bar where the mechanism ran.

Legend: **holds** = the mechanism survived M3 unchanged, **holds by
construction** = the sets core makes the bug impossible, **live check** =
holds on paper, not exercised on this build yet, **not addressed** = the
issue is untouched by 0.3.0, **fixed by 0.3.0** = closes with the release.

## Closed issues

| # | Issue | Mechanism | Verdict |
|---|---|---|---|
| 42 | Full bar, « overflow, misaligned clicks | Overflow gate (`overflowTrappedCount`), CoreServices agents unmanaged. Apply expands the « for drawn icons behind it (shielded HID click, editor only). | holds; the 0.2.40 wording "never clicks that «" is now "only while you press Apply" (notes say so) |
| 41 | AirDrop disappearing | Replica forces the system-extras hold | holds (code kept, no log hits today: no replica active on Gab's bar) |
| 40 | Context menu in the picture | Menu-fade guard on the picture | holds |
| 39 | Camera & mic dragging itself | Sets core: nothing moves on its own | holds by construction |
| 37 | Clock click opened the bar | Trigger zone middle→icon, dot AX press | holds (zone code kept) |
| 36 / 34 | Weather / Passwords can't hide | Apple hosts as apps, bundle keys | holds, live-proven today (`bundle:com.apple.Passwords.MenuBarExtra` in every converge) |
| 35 | Delay hiding/showing | Finished-picture lifecycle | holds and better: warm reveal 225–305ms → 20–45ms today |
| 33 | Window edge in the bar | BackdropWatch | holds, live (45 `backdrop: changed` lines today) |
| 31 | Always-hidden flash on relaunch | Adoption window under a cover (`coveringAdoption`) | holds, live-proven 2026-09-21 14:26 (Velja relaunch on build 49): `adopt: cover up … ready in 201ms` → `adoptWindow: dropping assertion` → adopted 249ms later → `cover down — concealed gone at 3ms, lifted at 433ms`, no uncovered frame |
| 30 / 14 | iStat, apps outside /Applications | Bundle-less host mark, absent bundles | holds (code kept; iStat itself still external) |
| 29 / 28 / 22 / 23 / 4 | Focus, timers, live activities | Replicas + collateral tracker (`destroyed by the bar` 26 lines today) | holds; live check with the Timer/Focus replica on |
| 27 | Notification Center on a side-by-side display | Display dedupe in the walk + clock relay | holds, live today; the new boot-wait rule (`98793fc`) uses the same display geometry |
| 25 / 5 | Strip flashes a different shade; own animation | SCStream cover, kept by the M3 cover decision | holds on paper; today's cover work (memoized pictures, chevron shift, window pool tried and dropped) is the one area that needs a day of eyes |
| 21 | Hover on the right half only | Band monitor, plus "hover zone includes the chevron" | holds |
| 20 | Settings CPU | Settings lifecycle | holds |
| 19 | Siri / Time Machine | Own extras; they enter the bar through the Apply door now | live-proven 2026-09-21 14:36 after two fixes: the own-item pass skipped a concealed section as "left layout" (guard order), and the boot repair forgot a singleton extra's section while it was off (Siri came back in Visible) |
| 18 | Shortcuts | HotkeyManager | holds |
| 15 | Glitching bar, immovable Electron icons | Old: three background retries then a note. New: no background moves at all; Apply reports a failed drag and the bounce budget stops it | holds by construction (the glitch was the retries) |
| 13 | Extra without an order slot crash | Enroll repair at boot | holds |
| 12 | Proton Drive sibling relaunch flashes | Relaunch adoption gated on the item owner's pid | live check: no `sibling` lines today (no such app running); code kept whole |
| 11 / 6 / 3 | Permissions and onboarding | Onboarding, permission probes | holds |
| 10 / 8 / 2 / 1 | Moved on / settings entry / ideas / Little Snitch | n/a | n/a |

## Open issues

| # | Issue | On 0.3.0 | Verdict |
|---|---|---|---|
| 32 | Opening Settings › Menu Bar reveals the icons | The editor no longer reveals the bar; the board is built from concealed items, Apply reveals and puts it back. Zero editor reveals in today's log. | **fixed by 0.3.0** — close in the release comment; the #23 "Apple items flash when the tab opens" remark is the same fix |
| 26 | Tray below the bar for hidden items | `floating-bar` branch, rebases after the merge | not in 0.3.0 |
| 44 | Option+A Notification Center shortcut dead while concealing | The assertion blocks the shortcut whatever presses it (OS policy). `334dc4b`: a Pelmet-owned ⌥⌘N under the clock toggle runs the relay's AX-press path; live 2026-09-21 18:39, NC open 232ms after the drop. | **shipped in beta.2, closed 2026-09-22** |
| 45 | Clock relay lights the recording dot, pointer jumps | PR #50 (robinhur) merged `7275210`: the blink cuts its cover from the idle picture, no capture at the click; the click that closes NC still captures (clock 3pt right while NC is open). Live 2026-09-22 08:26. **shipped in beta.2, closed 2026-09-22.** Earlier: | Pointer half ships (AX press). Dot half: the blink span (leftmost icon..clock) is wider than the fresh empty-strip picture, so most clicks still capture. The proposed "no capture" mode already exists: deny Screen Recording. | not addressed; reply with the permission route, a blink cover cut from the finished picture is the real fix (post-launch) |
| 46 | Bar blurs and freezes ~1s on a clock click | The blink picture. `334dc4b`: the 0.42s exit hold after the concealed items left the tree is gone (60fps burst 2026-09-21: no tail when lifting at once), the 300ms fixed verify sleep is a 30ms poll. Measured: click 940–1130ms → 670–685ms, dot zone/shortcut 800–870ms → 455ms. The rest is the agent's reveal slide and re-conceal. | **shipped in beta.2, closed 2026-09-22**, reporter asked to confirm |
| 49 | Bar picture retaken ~40× per reveal, indicator lights while windows move | The backdrop watch dropped AND retook the empty-bar picture on every change (1,818/day on a four-display Mac, 227 on Gab's, 67 of those followed by a bar approach). Now: drop only, retake when the pointer enters the hover zone or at the reveal itself (non-Smooth), reveal waits ≤0.6s for one in flight; the backdrop line names the mover. Live 2026-09-22 08:03. | **shipped in beta.2, closed 2026-09-22** |
| 48 | Opt-in beta channel | `docs/BETA-CHANNEL-PLAN.md` | plan written |

## What 0.3.0 changes that no issue covers (watch list for the beta)

- **An editor drop between sections hides the icon at once but leaves it
  where it sits** until Apply. The tile says "not in place". Users used to
  the icon jumping across the chevron will ask.
- **New icons land where macOS puts them** (the left end, the hidden side).
  With "new items go to Visible", a new icon sits physically on the hidden
  side and reads "not in place" until Apply.
- **The clock never moves and gets no launcher** (tile copy says so).
- **Boot with music playing on a multi-display Mac** (`98793fc`): the
  eight-second wait is gone on paper; not exercised live yet (music was off
  at the 11:51 and 11:58 boots).
- **Upgrade seed**: on Gab's bar it drew one pending move in Always Hidden
  (DBngin/Velja swapped); Apply or Discard clears it. Other users' stores
  may seed more.

## Gates before the merge

1. App test target with the host Pelmet quit (`xcodebuild test`), core
   tests already pass (128 + the new band test).
2. Live checks above, all done 2026-09-21 14:26–14:42 on Gab's bar: #31
   relaunch under a cover, #19 Siri toggle, a music-on boot (own items
   adopted 0.4s after launch), editor drop + Apply (verified drags), Discard.
   Watch: the Apply count is a concealed-bar estimate; one drop read (2) for
   a one-move pass and one one-count drop applied two. `apply: pending` log
   line names the counted moves now.
3. A day of eyes on the cover after today's picture work (#25 family).
