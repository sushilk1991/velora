#!/usr/bin/env python3
"""Small deterministic checks for the static public site."""

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
    parser = SiteParser()
    parser.feed(html)

    assert parser.h1_count == 1, "the product page must have exactly one h1"
    assert parser.canonical_hrefs == ["https://sushilk1991.github.io/velora/"], (
        "the landing page must declare the clean default URL as canonical"
    )
    assert "?v=" not in html, "cache-busting query parameters must not become public URLs"
    assert len(parser.ids) == len(set(parser.ids)), "HTML ids must be unique"
    assert {"main", "top", "how-it-works", "privacy", "iphone", "download"}.issubset(
        parser.ids
    ), "primary navigation targets must exist"
    assert "demo" in parser.ids, "the product demonstration must remain directly linkable"
    assert set(parser.demo_examples) == {"0", "1", "2"}, (
        "the dictation demo must keep all three user-controlled examples"
    )
    assert parser.hrefs.count("https://github.com/sushilk1991/velora/releases/latest") >= 3, (
        "download conversion paths must exist at the top, install section, and close"
    )
    assert parser.hrefs.count("https://github.com/sushilk1991/velora") >= 3, (
        "GitHub-star paths must exist in the navigation, hero, and close"
    )
    missing_fragments = sorted(
        href for href in parser.hrefs if href.startswith("#") and href[1:] not in parser.ids
    )
    assert not missing_fragments, (
        "in-page links must resolve: " + ", ".join(missing_fragments)
    )
    assert not parser.remote_executables, (
        "scripts and styles must remain self-hosted: " + ", ".join(parser.remote_executables)
    )

    missing = sorted(
        reference
        for reference in parser.local_assets
        if reference and not (SITE / reference).is_file()
    )
    assert not missing, "missing local site assets: " + ", ".join(missing)

    css = (SITE / "styles.css").read_text(encoding="utf-8")
    script = (SITE / "script.js").read_text(encoding="utf-8")
    assert ".section:not(.iphone-section)" in css, (
        "the full-bleed iPhone section must not inherit the capped section width"
    )
    public_source = "\n".join((html, css, script)).lower()
    assert "new line decisions" not in public_source, (
        "the demo must not imply that natural structure requires a spoken command"
    )
    assert "voice / 01" not in public_source and "live dictation demo" in public_source, (
        "the hero demo label must describe what the visitor is seeing"
    )
    assert "including browser playback" in public_source, (
        "the direct-dictation playback claim must include browser media"
    )
    assert "meeting capture leaves call audio running" in public_source, (
        "the playback claim must preserve the meeting-capture boundary"
    )
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
    assert "@media (prefers-reduced-motion: reduce)" in css, (
        "motion must keep an explicit reduced-motion path"
    )
    assert "if (reducedMotion || !animate)" in script, (
        "the JavaScript demo must settle immediately for reduced-motion users"
    )
    assert 'demoStage.classList.toggle("is-structured", index === 1)' in script, (
        "the inferred-list demo must use its compact multi-line treatment"
    )
    assert ".dictation-stage.is-structured .typed" in css, (
        "the inferred-list result must fit inside the demo card"
    )
    assert "height: clamp(36rem, 48vw, 38rem)" in css, (
        "switching examples must not resize the dictation card"
    )
    wave_speeds = [
        int(value) for value in re.findall(r"--wave-speed:\s*(\d+)ms", css)
    ]
    assert len(wave_speeds) == 11 and len(set(wave_speeds)) == 11, (
        "every waveform bar must keep an independent speech rhythm"
    )
    assert 800 <= min(wave_speeds) and max(wave_speeds) <= 1_000, (
        "active waveform bars must remain within the natural speech-rate timing band"
    )
    assert "@keyframes voice-bar" in css and "transform: scaleY(" in css, (
        "waveform motion must stay transform-only"
    )
    ready_wave = re.search(
        r"\.dictation-stage\.is-ready\s+\.waveform\s+i\s*\{([^}]*)\}",
        css,
        flags=re.DOTALL,
    )
    assert ready_wave and "animation: none" in ready_wave.group(1), (
        "the waveform must settle once the demo reaches ready state"
    )
    assert "type-caret" not in html and "type-caret" not in css, (
        "the demo must not reintroduce a detached output caret"
    )
    assert "pointermove" not in script and "--tilt-" not in css, (
        "pointer movement must not distort the demo card geometry"
    )
    assert (SITE / "assets/app-icon.png").stat().st_size <= 50_000, (
        "the shared site icon must remain below the 50 KB transfer budget"
    )
    assert '<script>document.documentElement.classList.add("js");</script>' in html, (
        "animated reveals must use an explicit progressive-enhancement gate"
    )
    visible_without_js = re.search(r"\.reveal\s*\{[^}]*opacity:\s*1", css, flags=re.DOTALL)
    hidden_with_js = re.search(r"\.js\s+\.reveal\s*\{[^}]*opacity:\s*0", css, flags=re.DOTALL)
    assert visible_without_js and hidden_with_js, (
        "reveal content must remain visible when JavaScript is unavailable"
    )

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

    truth_sources = "\n".join(
        (
            (ROOT / "README.md").read_text(encoding="utf-8"),
            (ROOT / "engine/src/velora_engine/models.py").read_text(encoding="utf-8"),
        )
    )
    storage_sizes = re.findall(r"\b\d+(?:\.\d+)? GB\b", html)
    assert all(size in truth_sources for size in storage_sizes), (
        "site storage claims must exist in README.md or the model registry"
    )

    print(f"site checks OK — {len(parser.local_assets)} local references")


if __name__ == "__main__":
    main()
