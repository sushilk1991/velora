"""Action Mode skills: fixed plans for commands whose steps are known.

The controller plans every command from the screen, one model turn at a time.
"Play X on YouTube" defeated it: the results page's first video sits ~940
nodes deep in Chrome's AX tree, past the 500-node snapshot, so the model
could never see or press it (and typed into the page instead, which the
foreground host cannot do). Owner decision, 2026-09-28: skills for the
everyday commands, the agent loop for the rest, and "play X on YouTube" ends
with the first result playing.

A skill is a rule, not a model call. It turns the command into the reply the
controller would have written; that reply takes the controller's own path
(`ActionSession.accept_reply` → `validate_plan`, then the app's independent
re-validation). Swift runs the steps and proves the result::

    "open YouTube and play lofi"
        │ youtube_play_query → "lofi"
        ▼
    open_url https://www.youtube.com/results?search_query=lofi
    play_first_video          ← Swift presses the first /watch link,
                                 then proves the watch page loaded

"Open github.com" and "search Google for X" defeated it too: with a browser
in front it typed into the address bar, which the foreground host cannot do,
until the turn budget ran out (live audit, 2026-10-28). One open_url is the
whole command::

    "open github.com in Chrome"          → open_url https://github.com
    "search Google for speech models"    → open_url https://www.google.com/search?q=speech+models
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING
from urllib.parse import parse_qs, urlencode, urlsplit

if TYPE_CHECKING:
    from .actions import ActionSession

PLAY_FIRST_VIDEO = "play_first_video"
YOUTUBE_RESULTS_URL = "https://www.youtube.com/results"
_YOUTUBE_HOSTS = frozenset(("youtube.com", "www.youtube.com", "m.youtube.com"))
_YOUTUBE_RESULTS_PATH = "/results"
_YOUTUBE_QUERY_KEY = "search_query"

# A spoken search is a few words; a paragraph is not a video title.
MAX_QUERY_WORDS = 12
MAX_QUERY_CHARS = 100

# The whole command must be one of three shapes, politeness aside:
#   "open YouTube and play X"   "play X on YouTube"   "YouTube, play X"
# "and", "then", or "and then" may join the first shape's halves.
# Anything after the query other than "for me" / "please" leaves the shape,
# so "play X on YouTube and send it to Priya" is the controller's.
_YOUTUBE_PLAY = re.compile(
    r"""^(?:(?:hey|ok|okay)\s+)?
        (?:(?:can|could|would|will)\s+you\s+)?
        (?:please\s+)?
        (?:
            (?:open|launch|start|go\s+to)\s+youtube\s*,?\s+
                (?:and\s+)?(?:then\s+)?play\s+(?P<after_open>.+?)
          | play\s+(?P<before_site>.+?)\s+(?:on|in|from)\s+youtube
          | youtube\s*,?\s+play\s+(?P<after_site>.+?)
        )
        (?:\s+for\s+me)?(?:\s+please)?$""",
    re.IGNORECASE | re.VERBOSE)
_WORD_RE = re.compile(r"[^\W_]+")

# A clause break left inside the query joins a second task: a comma or
# semicolon, a sentence end followed by more words, or a spaced dash.
#   "YouTube, play lofi, text it to Priya"   "… play lofi. Text it to Priya"
# A hyphen inside a word ("Lo-Fi") is not a break. The controller's.
_CLAUSE_BREAK = re.compile(r"[,;]|[.?!]\s+\S|\s[-\u2013\u2014]+\s")
# A conjunction or a delivery verb inside the query means a compound command
# ("open YouTube and play X and share it with Rahul"): the controller's.
_COMPOUND_WORDS = frozenset((
    "also", "and", "email", "forward", "message", "post", "reply", "send",
    "share", "then",
))
# "play this video on YouTube" means the video already on screen, not a
# search for the words "this video".
_REFERENCE_WORDS = frozenset((
    "current", "first", "it", "last", "my", "next", "previous", "same",
    "that", "the", "these", "this", "those",
))
_GENERIC_WORDS = frozenset((
    "clip", "music", "one", "song", "songs", "track", "video", "videos",
))


def youtube_play_query(transcript: str) -> str | None:
    """The search words of a "play X on YouTube" command, as spoken, or None.

    >>> youtube_play_query("Can you open YouTube and play lofi for me?")
    'lofi'
    >>> youtube_play_query("play it on YouTube") is None
    True
    """
    text = " ".join(transcript.split()).rstrip(".!?")
    match = _YOUTUBE_PLAY.match(text)
    if match is None:
        return None

    raw = next(group for group in match.groups() if group)
    query = raw.strip(" ,;:\"'")
    words = [word.casefold() for word in _WORD_RE.findall(query)]
    if not words or len(words) > MAX_QUERY_WORDS or len(query) > MAX_QUERY_CHARS:
        return None
    if _COMPOUND_WORDS.intersection(words) or _CLAUSE_BREAK.search(query):
        return None
    if (all(word in _REFERENCE_WORDS | _GENERIC_WORDS for word in words)
            and _REFERENCE_WORDS.intersection(words)):
        return None
    return query


def youtube_results_url(query: str) -> str:
    """https://www.youtube.com/results?search_query=Bollywood+Lo-Fi+music"""
    return f"{YOUTUBE_RESULTS_URL}?{urlencode({_YOUTUBE_QUERY_KEY: query})}"


def is_youtube_results_url(url: str) -> bool:
    """Whether `url` is a YouTube search results page with a query."""
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in _YOUTUBE_HOSTS:
        return False
    if parts.path != _YOUTUBE_RESULTS_PATH:
        return False

    queries = parse_qs(parts.query).get(_YOUTUBE_QUERY_KEY, [])
    return any(value.strip() for value in queries)


def reply_for(session: "ActionSession") -> dict | None:
    """The skill's controller-shaped turn 1 for this command, or None."""
    if session.finished or session.turns_used != 0:
        return None

    query = youtube_play_query(session.transcript)
    if query is None:
        return _web_page_reply(session)

    # Playing a video delivers nothing to anyone, and the whole command is
    # this one shape, so `sends: false` and `done` are both right.
    return {
        "goal": session.goal,
        "sends": False,
        "steps": [
            {"do": "open_url", "url": youtube_results_url(query)},
            {"do": PLAY_FIRST_VIDEO},
        ],
        "done": True,
    }


# ---- one web page -----------------------------------------------------------
# The link opens in the default browser, as the planner's own open_url does; a
# browser named in the command ("in Chrome") is accepted and not re-routed.

GOOGLE_SEARCH_URL = "https://www.google.com/search"
_GOOGLE_QUERY_KEY = "q"
# Sites spoken by name alone. A bare name is otherwise an app ("Open GitHub"
# is GitHub Desktop), so only sites with no Mac app of the same name belong.
_NAMED_SITES = {"youtube": "https://www.youtube.com"}
# Common web TLDs only, so a file name ("readme.md", "notes.txt") is no site.
_WEB_TLDS = frozenset((
    "ai", "au", "blog", "ca", "cloud", "co", "com", "de", "design", "dev",
    "edu", "fm", "fr", "gg", "gov", "in", "info", "io", "jp", "live", "ly",
    "me", "net", "news", "online", "org", "page", "shop", "site", "so",
    "store", "studio", "tech", "to", "tv", "uk", "us", "world", "xyz",
))
_HOST_PATH = re.compile(
    r"^(?P<host>[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+)"
    r"(?P<path>/[^\s]*)?$", re.IGNORECASE)

_POLITE_START = r"""(?:(?:hey|ok|okay)\s+)?
        (?:(?:can|could|would|will)\s+you\s+)?
        (?:please\s+)?"""
_IN_BROWSER = r"""(?:\s+(?:in|on|with|using)\s+
            (?:(?:google\s+)?chrome|safari|arc|firefox|brave
              |(?:microsoft\s+)?edge|opera|(?:the|my)\s+browser))?"""
_POLITE_END = r"(?:\s+for\s+me)?(?:\s+please)?$"

# "open github.com"   "go to github.com in Chrome"   "visit youtube"
_OPEN_SITE = re.compile(
    rf"""^{_POLITE_START}
        (?:open|go\s+to|visit|navigate\s+to)\s+(?P<site>\S+)
        {_IN_BROWSER}{_POLITE_END}""",
    re.IGNORECASE | re.VERBOSE)
# "search Google for X"   "search for X on Google"   "look up X on Google"
_GOOGLE = re.compile(
    rf"""^{_POLITE_START}
        (?:
            search\s+google\s+for\s+(?P<for>.+?)
          | (?:search(?:\s+for)?|look\s+up)\s+(?P<on>.+?)\s+on\s+google
        )
        {_IN_BROWSER}{_POLITE_END}""",
    re.IGNORECASE | re.VERBOSE)


def web_page_url(transcript: str) -> str | None:
    """The one page a "open <site>" or "search Google for X" command opens.

    >>> web_page_url("Open github.com in Chrome")
    'https://github.com'
    >>> web_page_url("Search Google for it") is None
    True
    """
    text = " ".join(transcript.split()).rstrip(".!?")
    site = _OPEN_SITE.match(text)
    if site is not None:
        return _site_url(site.group("site"))

    search = _GOOGLE.match(text)
    if search is None:
        return None
    query = _spoken_query(search.group("for") or search.group("on"))
    if query is None:
        return None
    return f"{GOOGLE_SEARCH_URL}?{urlencode({_GOOGLE_QUERY_KEY: query})}"


def _site_url(site: str) -> str | None:
    """https:// plus a spoken host (and path), or a named site's home page."""
    named = _NAMED_SITES.get(site.casefold())
    if named is not None:
        return named

    match = _HOST_PATH.match(site)
    if match is None:
        return None
    host = match.group("host").lower()
    if host.rsplit(".", 1)[-1] not in _WEB_TLDS:
        return None
    return f"https://{host}{match.group('path') or ''}"


def _spoken_query(raw: str) -> str | None:
    """A search query as spoken, or None when it is not one search.

    Same bounds as the YouTube query: a few words, no second task, and not
    only a reference to the screen ("search Google for it").
    """
    query = raw.strip(" ,;:\"'")
    words = [word.casefold() for word in _WORD_RE.findall(query)]
    if not words or len(words) > MAX_QUERY_WORDS or len(query) > MAX_QUERY_CHARS:
        return None
    if _COMPOUND_WORDS.intersection(words) or _CLAUSE_BREAK.search(query):
        return None
    if all(word in _REFERENCE_WORDS for word in words):
        return None
    return query


def _web_page_reply(session: "ActionSession") -> dict | None:
    """The web page skill's turn 1, or None."""
    url = web_page_url(session.transcript)
    if url is None:
        return None

    # Opening a page delivers nothing to anyone, and the page is the whole
    # command, so `sends: false` and `done` are both right.
    return {
        "goal": session.goal,
        "sends": False,
        "steps": [{"do": "open_url", "url": url}],
        "done": True,
    }
