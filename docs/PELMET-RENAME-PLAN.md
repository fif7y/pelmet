# Pelmet Transition Plan (nook → Pelmet)

Source decision: `~/Downloads/PELMET-RENAME.md` (cowork session, 2026-08-29).
This plan grounds that handoff in the **actual repo state** — two facts in the
handoff differ from reality and change the plan:

- Real bundle ID is **`app.fif7y.Nook`** (not `com.fif7y.nook`).
- Appcast is served from **gh-pages of fif7y/nook** →
  `https://fif7y.github.io/nook/appcast.xml`. **GitHub Pages URLs do NOT
  redirect after a repo rename** (only git/web URLs do). Renaming the repo
  kills the feed URL baked into every shipped binary. This is the single most
  dangerous step and drives the ordering below.

## Naming rules (from handoff, binding)

- Display: `Pelmet` (capital P, never PELMET/PelMet).
- Types/modules/targets: `Pelmet`, `PelmetCore`, `PelmetEngine`.
- Identifiers/paths/slugs: `pelmet` lowercase.
- No `PelmetBar` / `PelmetApp` / `PelmetKit` compounds.

## Decisions Gab must confirm before execution

1. **Bundle ID** — recommend **migrate** to `app.fif7y.Pelmet` now, while the
   user base is tiny (v0.1.4, days old). Migration: on first launch under new
   ID, if new suite empty and `app.fif7y.Nook` domain exists → copy all keys,
   write `migratedFromNook` marker, unregister old SMAppService login item,
   register new one, leave old domain on disk. (Keep-old-ID is the zero-risk
   fallback.)
2. **Appcast hosting** — recommend moving the canonical feed to
   `https://fif7y.github.io/pelmet/appcast.xml` for new builds, AND keeping the
   legacy URL alive: after renaming the repo, create a stub repo `fif7y/nook`
   whose gh-pages serves a copy of appcast.xml (release.sh pushes to both until
   legacy installs decay). Same EdDSA key everywhere (`SUPublicEDKey`
   unchanged, `_Assets/sparkle_private_key` untouched).

## Phases (order matters)

### Phase 0 — bridge release FIRST (as nook, v0.1.5)
Ship one last "nook" release whose only change is `SUFeedURL` →
the new pelmet feed URL (+ defaults-migration code if migrating bundle ID,
so it's in place before the renamed app arrives). Existing installs poll the
old URL, pick this up, and are now pointed at the future home. Release notes
lead with the rename announcement.

### Phase 1 — code rename
- `Packages/NookCore` → `Packages/PelmetCore`, `NookEngine` → `PelmetEngine`
  (dirs, Package.swift names/products/targets, `nook-probe` → `pelmet-probe`).
- All `import NookCore/NookEngine`; Xcode local package refs; `project.yml`
  (XcodeGen — target name, `PRODUCT_BUNDLE_IDENTIFIER`, `SUFeedURL`,
  `CFBundleName`/`CFBundleDisplayName`, copyright).
- `Nook/` app dir → `Pelmet/`, `NookTests` → `PelmetTests`, `NookLog` etc.
  ~256 `nook` hits in Swift — sweep with eyes on: some are prose/log strings,
  and macOS-27 engine strings (sectionKey grammar, plist keys, log subsystem)
  may be persisted state — audit `ItemIDGrammar` and any persisted-key
  constants before renaming those literals; persisted keys need migration, not
  blind rename.
- `scripts/release.sh`: `Nook-$VERSION.dmg` → `Pelmet-$VERSION.dmg`, perl
  re-point regex, scheme/app names, dual-appcast push (new + legacy stub).
- Verify Accessibility / Screen Recording prompts read "Pelmet" (they follow
  the app name; TCC grants are per-bundle-ID — migrating the ID means users
  re-grant permissions. Call this out in release notes + first-run UI).

### Phase 2 — GitHub
- Rename `fif7y/nook` → `fif7y/pelmet` (git/web redirects survive).
- Immediately create stub `fif7y/nook` repo, gh-pages serving legacy
  appcast.xml (per Decision 2).
- README: title, install instructions, badges, raw.githubusercontent links,
  hero SVG (`_Assets/hero.svg`, `nook-brand.svg`, `nook-logo-*.svg` → pelmet
  assets), About blurb. LICENSE header if it names nook.
- Homebrew: `fif7y/homebrew-tap` — new cask `pelmet`, old `nook` cask marked
  deprecated pointing at pelmet.

### Phase 3 — first Pelmet release (v0.2.0)
- Published to the NEW feed (and mirrored to legacy stub).
- Release notes lead with the rename + what migrated + permissions re-grant
  note (if bundle ID changed).

### Phase 4 — site
- `fif7y.com/apps/#nook` → `#pelmet`, old anchor kept working.
- Opening line: "A pelmet is the board above a window that hides the curtain
  hardware. This one does it for your menu bar." Tagline stays: *A calm menu
  bar for macOS.*
- New screenshots showing "Pelmet" in menus/About.

## Execution runbook — remaining manual steps (2026-08-29)

Code side is DONE (bridge commit `d55f924`, rename commit `a044f8c`, all tests
green). These GitHub-side steps need Gab (blocked for Claude by the permission
classifier):

```bash
# 1. Rename the repo (git/web URLs redirect; Pages URL moves)
gh repo rename pelmet -R fif7y/nook --yes
cd ~/Projects/Nook && git remote set-url origin https://github.com/fif7y/pelmet.git

# 2. Stub repo to keep the legacy feed URL alive
gh repo create fif7y/nook --public --description "Renamed to Pelmet → github.com/fif7y/pelmet"
cd "$(mktemp -d)" && git init -q -b gh-pages
git -C ~/Projects/Nook show origin/gh-pages:appcast.xml > appcast.xml
touch .nojekyll
printf '<meta http-equiv="refresh" content="0;url=https://github.com/fif7y/pelmet">' > index.html
git add -A && git commit -qm "Legacy appcast stub (app renamed to Pelmet)"
git remote add origin https://github.com/fif7y/nook.git && git push -u origin gh-pages
gh api -X POST repos/fif7y/nook/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'

# 3. Verify both feeds (Pages deploys take a few minutes)
curl -sI https://fif7y.github.io/pelmet/appcast.xml | head -1   # renamed repo's Pages
curl -sI https://fif7y.github.io/nook/appcast.xml | head -1     # stub

# 4. Bridge release v0.1.5 (nook code + new feed URL)
cd ~/Projects/Nook && git checkout d55f924 && scripts/release.sh
# → gh release create v0.1.5 with build/releases/Nook-0.1.5.dmg,
#   push appcast.xml to BOTH gh-pages (pelmet repo + nook stub)

# 5. Pelmet release v0.2.0
git checkout main && scripts/release.sh
# → gh release create v0.2.0 with build/releases/Pelmet-0.2.0.dmg,
#   push appcast.xml to both feeds again

# 6. Homebrew tap: in fif7y/homebrew-tap, add Casks/pelmet.rb (copy of nook.rb
#    with name/url/app updated), and mark Casks/nook.rb deprecated:
#      deprecate! date: "2026-08-29", because: :repo_renamed  # → pelmet
```

Also pending: site (`~/Projects/fif7y` — `#pelmet` anchor + pelmet opening
line), new wordmark SVGs (hero.svg + logo SVGs still draw "nook" as outline
paths — needs design, not sed), README screenshots.

## Verification (from handoff + repo-specific)

1. Clean `xcodebuild` — no residual `Nook` symbols.
2. `grep -ri nook .` → only intentional hits (changelog history, prose, legacy
   appcast stub, migration code constants).
3. About panel / Settings / menu read "Pelmet".
4. Defaults migration test: seed plist under `app.fif7y.Nook`, launch, confirm
   sections + per-display settings survive; login item registered under new
   ID, old one gone.
5. Sparkle chain test: build with OLD bundle+feed → confirm it's offered the
   bridge update and signature validates; then bridge build → confirm it's
   offered the Pelmet release from the new feed.
6. Legacy URL check after repo rename: `curl -I
   https://fif7y.github.io/nook/appcast.xml` → 200 from stub repo.
