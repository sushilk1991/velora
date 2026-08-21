# Velora website

The product site is intentionally static: HTML, CSS, and self-hosted scripts.
It has no analytics, tracking pixels, external font calls, CDN scripts, or
build-time framework. The display font (Instrument Serif) and three.js are
vendored into `assets/` so the page never calls out to a third party.

Structure:

- `index.html` — the landing page (hero WebGL "voice field", feature bento,
  feature index, honest comparison table).
- `features/*.html` — one page per capability, each ending in a "fine print"
  section that states the feature's honest boundaries.
- `compare/*.html` — the full comparison matrix plus Wispr Flow and
  Superwhisper deep dives. Claims are dated (checked August 2026) and sourced;
  update them when competitors change pricing or architecture.
- `assets/scene.js` — the three.js particle scene. Decorative only: pages
  render completely without WebGL or JavaScript, and the scene renders a
  single static frame under `prefers-reduced-motion`.

Preview it locally:

```sh
python3 -m http.server 8080 --directory site
```

Then open <http://localhost:8080>. `scripts/test-site.py` (part of `make test`)
encodes the promises the site makes — no tracking, no remote code, works
without JavaScript, honest claims — and now also checks every subpage.
The `pages.yml` workflow publishes this folder to GitHub Pages whenever a
site file changes on `main`.
