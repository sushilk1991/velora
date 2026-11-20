"""Declarative data tables for cue-gated cleanup rules (V-09)."""

from __future__ import annotations

# Curated spoken name -> emoji mapping. Applied ONLY when an explicit emoji cue
# fires and formatting != "light" — never on bare words in ordinary prose.
EMOJI_TABLE: dict[str, str] = {
    "thumbs up": "👍",
    "thumbs down": "👎",
    "heart": "❤️",
    "red heart": "❤️",
    "fire": "🔥",
    "smile": "😊",
    "smiley": "😊",
    "laugh": "😂",
    "laughing": "😂",
    "joy": "😂",
    "rocket": "🚀",
    "check": "✅",
    "checkmark": "✅",
    "warning": "⚠️",
    "party": "🎉",
    "tada": "🎉",
    "clap": "👏",
    "clapping": "👏",
    "eyes": "👀",
    "thinking": "🤔",
    "wave": "👋",
    "waving": "👋",
    "100": "💯",
    "hundred": "💯",
    "pray": "🙏",
    "sparkles": "✨",
    "shrug": "🤷",
}

# Homophone disambiguation entries: (trigger_words, concise_disambiguation_hint).
# Only entries whose words actually appear in the transcript are emitted.
HOMOPHONE_TABLE: tuple[tuple[frozenset[str], str], ...] = (
    (frozenset({"brakes", "breaks"}), "a vehicle's `brakes` (not `breaks`); pauses or fractures are `breaks`"),
    (frozenset({"reins", "reigns"}), "a horse's or control `reins` (not `reigns`); a monarch `reigns`"),
    (frozenset({"aisle", "isle"}), "a store or plane `aisle` (not `isle`); an island is an `isle`"),
    (frozenset({"cereal", "serial"}), "`cereal` to eat (not `serial`); a sequence or number is `serial`"),
    (frozenset({"peak", "peek", "pique"}), "a mountain or maximum `peak`, a quick `peek`, `pique` interest"),
    (frozenset({"affect", "effect"}), "usually verb `affect` (influence) vs noun `effect` (result)"),
    (frozenset({"compliment", "complement"}), "praise is `compliment`; completing or pairing is `complement`"),
    (frozenset({"principal", "principle"}), "a school head or main sum is `principal`; a rule or belief is `principle`"),
    (frozenset({"stationary", "stationery"}), "not moving is `stationary`; paper/envelopes are `stationery`"),
    (frozenset({"discreet", "discrete"}), "careful/private is `discreet`; separate/distinct is `discrete`"),
    (frozenset({"elicit", "illicit"}), "draw out a response is `elicit`; illegal is `illicit`"),
    (frozenset({"counsel", "council"}), "advice/lawyer is `counsel`; an assembly/committee is `council`"),
    (frozenset({"lose", "loose"}), "misplace or fail to win is `lose`; not tight is `loose`"),
    (frozenset({"weather", "whether"}), "rain/sun is `weather`; introducing alternatives is `whether`"),
    (frozenset({"whose", "who's"}), "possessive `whose` vs contraction `who's` (who is / who has)"),
)

# Explicit take-back phrases (kept as a single authoritative table consumed by
# cue detection and the take_backs rule).
TAKE_BACK_PHRASES: tuple[str, ...] = (
    "scratch that",
    "scratch all of that",
    "forget that",
    "never mind",
    "cancel that",
    "delete that",
    "delete this line",
)
