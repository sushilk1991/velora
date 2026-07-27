#!/usr/bin/env python3
"""Small deterministic checks for the static public site.

These encode the promises the site makes — no tracking, no remote code, works
without JavaScript, honest claims — rather than the current visual design.
"""

from __future__ import annotations

from html import unescape
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []
        self.local_assets: list[str] = []
        self.remote_executables: list[str] = []
        self.hrefs: list[str] = []
        self.canonical_hrefs: list[str] = []
        self.demo_examples: list[str] = []
        self.h1_count = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if element_id := values.get("id"):
            self.ids.append(element_id)
        if tag == "h1":
            self.h1_count += 1
        if tag == "a" and (href := values.get("href")):
            self.hrefs.append(href)
        if tag == "link" and values.get("rel") == "canonical" and (href := values.get("href")):
            self.canonical_hrefs.append(href)
        if example := values.get("data-demo-example"):
            self.demo_examples.append(example)

        reference = values.get("src") or values.get("href")
        if not reference:
            return
        parsed = urlparse(reference)
        if tag == "script" or (tag == "link" and values.get("rel") == "stylesheet"):
            if parsed.scheme in {"http", "https"}:
                self.remote_executables.append(reference)
        if not parsed.scheme and not reference.startswith("#"):
            self.local_assets.append(parsed.path)


def main() -> None:
    html = (SITE / "index.html").read_text(encoding="utf-8")
    css = (SITE / "styles.css").read_text(encoding="utf-8")
    script = (SITE / "script.js").read_text(encoding="utf-8")
    parser = SiteParser()
    parser.feed(html)

    # --- structure and navigation -------------------------------------------
    assert parser.h1_count == 1, "the product page must have exactly one h1"
    assert parser.canonical_hrefs == ["https://sushilk1991.github.io/velora/"], (
        "the landing page must declare the clean default URL as canonical"
    )
    assert "?v=" not in html, "cache-busting query parameters must not become public URLs"
    assert len(parser.ids) == len(set(parser.ids)), "HTML ids must be unique"
    assert {
        "main",
        "top",
        "how-it-works",
        "anywhere",
        "privacy",
        "iphone",
        "download",
        "faq",
    }.issubset(parser.ids), "primary navigation targets must exist"
    assert "demo" in parser.ids, "the product demonstration must remain directly linkable"
    missing_fragments = sorted(
        href for href in parser.hrefs if href.startswith("#") and href[1:] not in parser.ids
    )
    assert not missing_fragments, (
        "in-page links must resolve: " + ", ".join(missing_fragments)
    )

    # --- conversion paths ----------------------------------------------------
    assert parser.hrefs.count("https://github.com/sushilk1991/velora/releases/latest") >= 3, (
        "download conversion paths must exist at the top, install section, and close"
    )
    assert parser.hrefs.count("https://github.com/sushilk1991/velora") >= 3, (
        "GitHub-star paths must exist in the navigation, install section, and close"
    )

    # --- self-hosting and privacy -------------------------------------------
    assert not parser.remote_executables, (
        "scripts and styles must remain self-hosted: " + ", ".join(parser.remote_executables)
    )
    missing = sorted(
        reference
        for reference in parser.local_assets
        if reference and not (SITE / reference).is_file()
    )
    assert not missing, "missing local site assets: " + ", ".join(missing)

    public_source = "\n".join((html, css, script)).lower()
    forbidden = ("google-analytics", "googletagmanager", "mixpanel", "posthog", "segment.io")
    assert not any(marker in public_source for marker in forbidden), (
        "the public site must not add analytics or tracking"
    )
    assert not re.search(r"https?://", script, flags=re.IGNORECASE), (
        "site JavaScript must not make or embed remote network requests"
    )
    assert not re.search(
        r"\b(?:fetch|XMLHttpRequest|WebSocket|EventSource)\s*\(",
        script,
    ), "site JavaScript must remain presentation-only"
    assert not re.search(
        r"(?:@import\s+(?:url\()?|url\()\s*['\"]?https?://",
        css,
        flags=re.IGNORECASE,
    ), "site CSS must not load remote resources"
    assert (SITE / "assets/app-icon.png").stat().st_size <= 50_000, (
        "the shared site icon must remain below the 50 KB transfer budget"
    )

    # --- works without JavaScript -------------------------------------------
    assert 'classList.add("js")' in html, (
        "animated reveals must use an explicit progressive-enhancement gate"
    )
    visible_without_js = re.search(r"\.reveal\s*\{[^}]*opacity:\s*1", css, flags=re.DOTALL)
    hidden_with_js = re.search(r"\.js\s+\.reveal\s*\{[^}]*opacity:\s*0", css, flags=re.DOTALL)
    assert visible_without_js and hidden_with_js, (
        "reveal content must remain visible when JavaScript is unavailable"
    )
    assert "demo-nojs-raw" in html and "demo-nojs-out" in html, (
        "the dictation demo must show a plain before/after when scripting is off"
    )
    assert ".js .demo-nojs { display: none; }" in css, (
        "the scripted demo and its no-JS fallback must never both be visible"
    )
    assert "html:not(.js) .demo-line" in css, (
        "the scripted demo container must stay hidden without JavaScript"
    )
    assert "html:not(.js) .demo-controls" in css and "html:not(.js) .copy-command" in css, (
        "controls that only work with scripting must not be shown without it"
    )

    # A reveal that never fires is a blank page, so the IntersectionObserver
    # needs a non-observer path behind it.
    assert (
        "IntersectionObserver" in script
        and "getBoundingClientRect().top > window.innerHeight" in script
    ), "scroll reveals must have a timeout fallback so the page cannot render empty"

    # --- both themes ---------------------------------------------------------
    assert "color-scheme: light dark" in css, "the site must honour the visitor's theme"

    # light-dark() needs Safari 17.5+; macOS 14 shipped with Safari 17.0, where
    # every light-dark() token is invalid at computed-value time and the page
    # loses its palette. Comments may mention it; declarations may not.
    css_without_comments = re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)
    assert "light-dark(" not in css_without_comments, (
        "light-dark() is not supported on every macOS version Velora targets"
    )

    assert ':root[data-theme="light"]' in css and ':root[data-theme="dark"]' in css, (
        "the explicit theme toggle must be able to override the media query"
    )

    def declared(block: str) -> dict[str, str]:
        return dict(re.findall(r"(--[\w-]+):\s*([^;]+);", block))

    def block_after(marker: str) -> str:
        start = css.index(marker) + len(marker)
        return css[start : css.index("\n  }", start) if marker.startswith("@media") else css.index("\n}", start)]

    light_tokens = declared(css[css.index(":root {") : css.index("\n}", css.index(":root {"))])
    media_dark = declared(block_after('@media (prefers-color-scheme: dark) {\n  :root:not([data-theme="light"]) {'))
    attr_dark = declared(block_after(':root[data-theme="dark"] {'))

    # The dark palette is written twice — once for the media query, once for the
    # explicit choice. Drift between them shows up only in one of the two paths.
    assert media_dark and media_dark == attr_dark, (
        "the media-query and explicit dark palettes must stay identical"
    )
    orphans = sorted(set(media_dark) - set(light_tokens))
    assert not orphans, "dark-only tokens have no light value: " + ", ".join(orphans)
    assert "--feature" not in media_dark, (
        "feature bands must keep one colour across both themes"
    )
    assert {"--bg", "--ink", "--line", "--accent"} <= set(media_dark), (
        "the dark theme must override the core surface, text, line, and accent tokens"
    )
    assert "velora-theme" in html and html.index('classList.add("js")') < html.index(
        'rel="stylesheet"'
    ), "the stored theme must be applied before the stylesheet so there is no flash"
    assert "data-theme-toggle" in html and "velora-theme" in script, (
        "the theme toggle must persist the visitor's choice"
    )
    assert re.search(r'name="theme-color"[^>]*prefers-color-scheme: dark', html), (
        "the browser chrome colour must follow the dark theme too"
    )
    # --- motion --------------------------------------------------------------
    assert "@media (prefers-reduced-motion: reduce)" in css, (
        "motion must keep an explicit reduced-motion path"
    )
    assert "if (reducedMotion()) {" in script and "settle(example)" in script, (
        "the dictation demo must settle immediately for reduced-motion visitors"
    )
    assert not re.search(r"transition:\s*all\b", css), (
        "transitions must name their properties so unrelated changes do not animate"
    )
    assert "@keyframes voice-bar" in css and "scale: 1 var(--wave-peak)" in css, (
        "waveform motion must stay compositor-friendly"
    )
    wave_speeds = [int(value) for value in re.findall(r"--wave-speed:\s*(\d+)ms", css)]
    assert len(wave_speeds) >= 8 and len(set(wave_speeds)) == len(wave_speeds), (
        "every waveform bar must keep an independent speech rhythm"
    )
    assert 800 <= min(wave_speeds) and max(wave_speeds) <= 1_000, (
        "active waveform bars must remain within the natural speech-rate timing band"
    )

    # --- the dictation demo --------------------------------------------------
    assert set(parser.demo_examples) == {"0", "1", "2"}, (
        "the dictation demo must keep all three visitor-controlled examples"
    )
    stage_rules = css[css.index(".demo-stage {") :]
    assert re.search(r"height: clamp\(", stage_rules[:400]), (
        "switching examples or replaying must not resize the dictation card"
    )
    # Tokens are measured rather than sized by a flexible grid track: a flexible
    # track lets a token shrink into whatever space is left on the line, which
    # silently truncates the transcript instead of wrapping it.
    assert '--w", `${token.getBoundingClientRect().width}px`' in script, (
        "diff tokens must animate from a measured width"
    )
    assert "void line.offsetWidth;" in script and "is-sized" in css, (
        "token transitions must be enabled only after the measured width is committed"
    )
    # Once in render(), once in showRaw(). Without the render() reset, going
    # from a list example back to a diff example leaves the line hidden and the
    # card renders empty.
    assert script.count("line.hidden = false;") >= 2, (
        "switching from a list example back to a diff example must unhide the line"
    )
    assert "data-demo-live" in html and 'aria-live="polite"' in html, (
        "demo state changes must be announced to assistive technology"
    )
    # A zero-width token is still in the accessibility tree and still copied
    # with a selection, so it has to be hidden properly, not just squeezed.
    assert 'token.setAttribute("aria-hidden", "true")' in script, (
        "collapsed diff tokens must leave the accessibility tree"
    )
    assert "void list.offsetWidth;" in script, (
        "the structured result must not depend on a frame callback to become visible"
    )
    assert "pointerdown" in script and "keydown" in script and "keyup" in script, (
        "hold-to-dictate must work with a pointer and with a keyboard"
    )

    # --- honest claims -------------------------------------------------------
    assert "new line decisions" not in public_source, (
        "the demo must not imply that natural structure requires a spoken command"
    )
    assert "including browser playback" in public_source, (
        "the direct-dictation playback claim must include browser media"
    )
    assert "meeting capture leaves call audio running" in public_source, (
        "the playback claim must preserve the meeting-capture boundary"
    )

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    ios_readme = (ROOT / "ios/README.md").read_text(encoding="utf-8")
    models = (ROOT / "engine/src/velora_engine/models.py").read_text(encoding="utf-8")

    # The iPhone app is alpha. Every surface that mentions it has to say so.
    for name, text in (("README.md", readme), ("ios/README.md", ios_readme), ("the site", html)):
        lowered = text.lower()
        assert "alpha" in lowered and "not stable" in lowered, (
            f"{name} must state that the iPhone app is alpha and not stable"
        )
    assert "app store" in html.lower() and "testflight" in html.lower(), (
        "the site must be explicit that the iPhone app has no App Store or TestFlight build"
    )

    truth_sources = "\n".join((readme, models))
    storage_sizes = re.findall(r"\b\d+(?:\.\d+)? GB\b", html)
    assert all(size in truth_sources for size in storage_sizes), (
        "site storage claims must exist in README.md or the model registry"
    )
    language_claims = re.findall(r"(\d+)</span> languages", html)
    assert language_claims, "the multilingual claim must stay on the page"
    assert all(f"{count} languages" in models for count in language_claims), (
        "site language claims must exist in the model registry"
    )

    # --- the copied command must be the command shown ------------------------
    copy_match = re.search(r'data-copy="([^"]+)"', html)
    visible_match = re.search(
        r"<pre><code><span[^>]*>.*?</span>\s*([^<]+)</code></pre>",
        html,
        flags=re.DOTALL,
    )
    assert copy_match and visible_match, "the Homebrew command needs copy and visible forms"
    assert unescape(copy_match.group(1)).strip() == unescape(visible_match.group(1)).strip(), (
        "the copied Homebrew command must match the visible command"
    )

    print(f"site checks OK — {len(parser.local_assets)} local references")


if __name__ == "__main__":
    main()
