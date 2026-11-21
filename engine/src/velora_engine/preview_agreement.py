"""LocalAgreement stability gate for Stream Typing previews.

Consecutive previews re-decode a growing open span, so their trailing words
are volatile: the newest word is routinely rewritten by the next decode.
Showing every raw preview makes the draft visibly flicker. LocalAgreement
(confirmed = the longest common prefix of two consecutive hypotheses) only
promotes a word once two windows agree on it:

    preview 1   "hello brave world"     confirmed ""
    preview 2   "hello brave word"      confirmed "hello brave"
    preview 3   "hello brave word now"  confirmed "hello brave word"

Words match case- and punctuation-insensitively, but the confirmed text
carries the *latest* surface form, so a later "Hello," replaces "hello"
without un-confirming the word. Confirmed words never shrink or change
identity within a span (that monotonicity is the anti-flicker guarantee);
a rewrite that contradicts the confirmed prefix is ignored until the span
resets, which the backends do when a segment commits.

`update` is the pure gate. `display_update` is the Stream Typing display
policy built on it, with two deliberate passthroughs (see its docstring):
a span's first preview shows in full so a lone preview still appears, and
a preview sharing no prefix word with its predecessor restarts the span
instead of blanking the draft.
"""

from __future__ import annotations

import re

_EDGE_JUNK = re.compile(r"^[\W_]+|[\W_]+$", re.UNICODE)


def _word_key(word: str) -> str:
    """Match key for one word: casefolded, edge punctuation stripped.

    Internal punctuation survives ("don't", "well-known"). A token that is
    pure punctuation keys on itself, so "," and "." never agree.
    """
    return _EDGE_JUNK.sub("", word.casefold()) or word.casefold()


class StreamingLocalAgreement:
    """Two-window LocalAgreement over word sequences, per open span."""

    def __init__(self) -> None:
        self._prev_words: list[str] | None = None
        self._prev_keys: list[str] = []
        self._confirmed_words: list[str] = []
        self._confirmed_keys: list[str] = []
        self._latest_words: list[str] = []
        # Prefix length shared by the last two windows; None until a pair
        # has been compared. display_update uses 0 to spot a full rewrite.
        self._last_common_words: int | None = None

    # -- state views ---------------------------------------------------------

    @property
    def confirmed_text(self) -> str:
        """Words two consecutive windows agreed on, latest surface form."""
        return " ".join(self._confirmed_words)

    @property
    def latest_text(self) -> str:
        """The most recent raw hypothesis, whitespace-normalized."""
        return " ".join(self._latest_words)

    @property
    def tentative_text(self) -> str:
        """Latest words past the confirmed prefix (not yet agreed)."""
        return " ".join(self._latest_words[len(self._confirmed_words):])

    @property
    def has_previous(self) -> bool:
        """Whether any window has been seen since the last reset."""
        return self._prev_words is not None

    # -- gate ------------------------------------------------------------------

    def reset(self) -> None:
        self._prev_words = None
        self._prev_keys = []
        self._confirmed_words = []
        self._confirmed_keys = []
        self._latest_words = []
        self._last_common_words = None

    def update(self, text: str | None) -> str:
        """Feed one preview hypothesis; return the confirmed prefix.

        Empty/whitespace input is not a window: it neither confirms nor
        replaces the previous hypothesis, and the current confirmed text
        comes back unchanged. A first window confirms nothing.
        """
        words = (text or "").split()
        if not words:
            return self.confirmed_text
        keys = [_word_key(word) for word in words]
        self._latest_words = words

        if self._prev_words is None:
            self._prev_words, self._prev_keys = words, keys
            self._last_common_words = None
            return self.confirmed_text

        common = 0
        for old_key, new_key in zip(self._prev_keys, keys, strict=False):
            if old_key != new_key:
                break
            common += 1
        self._last_common_words = common
        self._prev_words, self._prev_keys = words, keys

        if common > len(self._confirmed_words):
            self._confirmed_words = words[:common]
            self._confirmed_keys = keys[:common]
        elif keys[: len(self._confirmed_words)] == self._confirmed_keys:
            # Same confirmed words, possibly re-cased or re-punctuated by the
            # newer decode: take its surface form without moving the gate.
            self._confirmed_words = words[: len(self._confirmed_words)]
        # else: the new window contradicts confirmed words. Keep them —
        # retracting shown text is exactly the flicker this gate prevents.
        return self.confirmed_text

    def display_update(self, text: str | None) -> str:
        """Feed one preview; return what Stream Typing may show for the span.

        Normally the confirmed prefix (volatile tail held). Passthroughs:

        - First window of a span: shown in full. Nothing precedes it, so it
          cannot flicker yet, and a take that stops after one preview (the
          pre-existing single-`decode_preview` contract) still shows text.
          The cost is one possible retraction when window two disagrees.
        - Zero shared prefix with the previous window: the hypothesis was
          rewritten from word one — corrected first word, or the capped
          preview window slid to newer audio. Restart agreement on the new
          text and show it in full rather than leaving stale words up (or
          blanking the draft) until two rewritten windows happen to agree.

        Empty input returns the current confirmed text ("" before any
        agreement), never stale raw words.
        """
        words = (text or "").split()
        if not words:
            return self.update(text)
        first = not self.has_previous
        stable = self.update(text)
        if first:
            return " ".join(words)
        if self._last_common_words == 0:
            self.reset()
            self.update(text)
            return " ".join(words)
        return stable
