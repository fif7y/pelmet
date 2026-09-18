# DMG background

`background.html` is the source. `background.png` (660×400) and `background@2x.png`
(1320×800) are rendered from it; `background.tiff` bundles both so Finder picks the
Retina one. `make-dmg.sh` copies the tiff into the volume and lays the window out
(660×400, icons at 128pt, Pelmet at 168,182, Applications at 492,182).

Re-render after editing the HTML:

```sh
cd scripts/dmg
python3 -m http.server 8931 &
node -e '
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ deviceScaleFactor: 2 });
  await p.goto("http://localhost:8931/background.html");
  await p.locator("#bg").screenshot({ path: "background@2x.png", scale: "device" });
  await p.locator("#bg").screenshot({ path: "background.png", scale: "css" });
  await b.close();
})();'
tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
kill %1
```

Check the result on a real volume: `scripts/make-dmg.sh <Pelmet.app> /tmp/t.dmg && open /tmp/t.dmg`.
If the window opens at Finder's default size instead of 660×400, the `.DS_Store` did
not flush — the script closes and reopens the window once and sleeps before detaching;
keep that order.
