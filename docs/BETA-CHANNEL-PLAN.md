# Beta channel plan (#48, 2026-09-21)

Goal: most releases go out as opt-in betas, several a week if needed; the
stable channel gets one roll-up every one or two weeks. People who never
opt in see one update at a time and one set of notes.

## How Sparkle does channels

- An appcast `<item>` can carry `<sparkle:channel>beta</sparkle:channel>`.
  Items without a channel are stable.
- A client includes channel items only when its `SPUUpdaterDelegate`
  returns that channel from `allowedChannelsForUpdater:` (Sparkle 2.9.6,
  the version Pelmet ships). Stable clients never see beta items.
- `generate_appcast --channel beta` stamps the items it creates in that
  run; existing items keep their (absent) channel. One `appcast.xml` on
  gh-pages serves both channels.
- Sparkle picks the highest `sparkle:version` (CFBundleVersion) among the
  items a client is allowed to see. So build numbers stay one monotonic
  counter across both channels (48, 49, 50…), never per channel.
- Deltas: `generate_appcast` builds deltas between the DMGs it finds in
  `build/releases`, channel or not. Raise `--maximum-versions` (3 today) so a
  stable user two roll-ups back still gets a delta.

## App side (small)

- Setting `betaUpdates: Bool` (default off) in the settings blob, resilient
  decode. Toggle in Settings › About under "Notify me about updates":
  "Get beta releases" with the caption "Smaller updates, more often. Stable
  releases roll them up every week or two."
- `allowedChannelsForUpdater:` returns `["beta"]` when on. Turning it on
  runs a check at once; turning it off never downgrades (Sparkle won't) —
  the user stays on their beta until the next stable build number passes
  it, which the roll-up cadence guarantees within two weeks.
- The update banner, chip and notification say "beta" when
  `SUAppcastItem.channel == "beta"`, so a beta user always knows which
  train they are on.

## Release side

- `scripts/release.sh` takes `CHANNEL=beta`: passes `--channel beta` to
  `generate_appcast`, creates the GitHub release with `--prerelease`, skips
  the Homebrew tap (the cask tracks stable only), and mirrors the same
  appcast to the nook feed as today (one file, the channel tag does the
  filtering).
- Versions: betas are `X.Y.Z-beta.N` in MARKETING_VERSION (SemVer
  pre-release, sorts below `X.Y.Z` for humans; Sparkle ignores it and uses
  the build number). Tag `vX.Y.Z-beta.N`. The stable is a fresh build from
  the last beta's commit with MARKETING_VERSION `X.Y.Z` and the next build
  number — never the beta binary re-tagged, the version string differs.
- Notes: `docs/release-notes/vX.Y.Z-beta.N.md` per beta; the stable's notes
  are the roll-up of its betas, edited once for stable readers (they never
  saw the beta notes).
- README download badge: `github/v/release` skips pre-releases, so the
  badge and "Latest" stay on stable with no change.

## Cadence and issue etiquette

- Beta: whenever a fix or a feature lands and a dev build has held on
  Gab's bar. Several a week is fine, that is what the channel is for.
- Stable: a fixed day (Tuesday), every one or two weeks, from the last beta
  that has had at least two days without a new beta-only bug. A bug in the
  stable itself gets a hotfix stable, not a beta.
- Issues: a fix ships to beta first. The comment says "in 0.3.1-beta.2,
  turn on Get beta releases in About to take it now; stable next Tuesday".
  Close at the beta (the reporter can verify) — keeps the current close
  convention, just one step earlier. The share line rotates as today.

## Rollout order

1. **0.2.41 stable from main**: the toggle + delegate + release.sh flag,
   nothing else. Stable users need the opt-in before any beta exists.
2. **0.3.0-beta.1 from `roster`** on the beta channel: the sets core goes
   out to people who chose to follow. A week of beta with the watch list in
   `docs/ISSUE-AUDIT-0.3.0.md`.
3. **0.3.0 stable** once the beta has held: notes roll-up, cask bump, mirror.

This makes the sets-core switch itself the first use of the channel, which
is the safest way to ship it.

## Open questions for Gab

- Beta version string: `0.3.0-beta.1` (proposed) or `0.3.0b1`?
- Stable day: Tuesday (proposed, matches the PH/launch rhythm) or Thursday?
- Close issues at the beta (proposed) or wait for the stable?
- Should the beta toggle be offered once in the update banner ("Want fixes
  sooner? Get beta releases") or stay a quiet About setting (proposed)?
