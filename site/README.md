# Velora website

The product site is intentionally static: HTML, CSS, and a small progressive
enhancement script. It has no analytics, tracking pixels, external font calls,
or build-time framework.

Preview it locally:

```sh
python3 -m http.server 8080 --directory site
```

Then open <http://localhost:8080>. The `pages.yml` workflow publishes this
folder to GitHub Pages whenever a site file changes on `main`.
