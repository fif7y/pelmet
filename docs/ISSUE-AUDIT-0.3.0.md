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
| 31 | Always-hidden flash on relaunch | Adoption window under a cover (`coveringAdoption`) | live check: relaunch an Always Hidden app, expect `adoptWindow` + an `adopt` cover, no flash (2 windows opened today, cover not read) |
| 30 / 14 | iStat, apps outside /Applications | Bundle-less host mark, absent bundles | holds (code kept; iStat itself still external) |
| 29 / 28 / 22 / 23 / 4 | Focus, timers, live activities | Replicas + collateral tracker (`destroyed by the bar` 26 lines today) | holds; live check with the Timer/Focus replica on |
| 27 | Notification Center on a side-by-side display | Display dedupe in the walk + clock relay | holds, live today; the new boot-wait rule (`98793fc`) uses the same display geometry |
| 25 / 5 | Strip flashes a different shade; own animation | SCStream cover, kept by the M3 cover decision | holds on paper; today's cover work (memoized pictures, chevron shift, window pool tried and dropped) is the one area that needs a day of eyes |
| 21 | Hover on the right half only | Band monitor, plus "hover zone includes the chevron" | holds |
| 20 | Settings CPU | Settings lifecycle | holds |
| 19 | Siri / Time Machine | Own extras; they enter the bar through the Apply door now | live check: toggle Siri on, expect `apply: own … applied=1` |
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
| 44 | Option+A Notification Center shortcut dead while concealing | The assertion blocks the shortcut (same OS policy as the clock click, memory `ASSERTION-BLOCKS-CLOCK→NC-CLICK`). Only in-app route: a keyboard relay like the clock relay (event tap on the configured shortcut → drop the assertion → replay). | not addressed; decide |
| 45 | Clock relay lights the recording dot, pointer jumps | By design: the blink cover captures the strip (lights the dot when no fresh picture exists) and replays the click at the clock's centre with a cursor warp when it landed on the dot. | not addressed; two cheap softenings: reuse the finished picture for the blink when it is fresh (no capture), and restore the pointer after the replay |
| 46 | Bar blurs and freezes ~1s on a clock click | The blink cover stays up until the conceal reflow lands: today's log reads `cover down — concealed gone at 912ms, lifted at 1333ms` and `0ms / 436ms`. | not addressed; same mechanism as #45, the 900ms case is the reflow, not Pelmet |
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
2. Live checks above: #31 relaunch under a cover, #19 Siri toggle, a
   music-on boot, one editor drop + Apply, one Discard.
3. A day of eyes on the cover after today's picture work (#25 family).
