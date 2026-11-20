"""Phonetic post-decode glossary corrector (V-12 Step 1 — zero-model, ~0 MB RAM).

Fixes proper nouns and technical jargon misheard by STT backends — especially
Parakeet (which ignores Whisper's ``initial_prompt``) — using a deterministic
phonetic skeleton + bounded edit distance over user vocabulary and screen
entities.

Safety invariants against false replacements:
- Never modifies quoted or backticked spans.
- Never fuzzy-replaces short terms (<4 letters) or common English words.
- Requires matching initial phonetic class, matching/near-matching phonetic
  skeleton, tight edit distance, and a unique unambiguous winner.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Collection

_PROTECTED_SPAN_RE = re.compile(r'(`[^`\n]*`|"[^"\n]*")')
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'\-]*")

# High-frequency ordinary English words that must NEVER be fuzzy-replaced by a
# similar-sounding glossary term (e.g., "file" must never turn into "Kile",
# "great" must never turn into "Gradle", "merge" must never turn into "Marge").
_COMMON_ENGLISH_WORDS = frozenset(
    "about above across after again against almost alone along already also always "
    "among another answer anyone anything around asked asking away back balance "
    "based basic became because become been before began begin behind being below "
    "bench better between beyond black block blood board books both bottom bought "
    "bound box brain branch brand break brief bring broad broke brown budget build "
    "built bunch burst button buyer cable cache called calling calls came camera "
    "cancel cannot cards carry cases catch cause center centre chain chair chance "
    "change charge chart check chest chief child china choice choose chose chunk "
    "claim class clean clear click client clock close closed closer cloud coach "
    "coast codes coding coffee cold color colour comes coming common company "
    "compare complete confirm connect consider contact content context continue "
    "control cookie copied copies copy corner correct cost could count counter "
    "country couple course court cover crash create credit cross crowd current "
    "cursor custom cycle daily damage dance dark data date dates days dead deal "
    "deals death debug decide decision deep default delay delete deliver delta "
    "depth describe design desk detail details detect device devices dialog "
    "didn't diff differ direct dirty disable discard disk display done don't door "
    "double doubt down draft drag draw dream dress drink drive driver drop dropped "
    "during each early earth east easy edit edited editor effect effort eight "
    "either else email empty enable ended ending engine enough ensure enter entire "
    "entry equal error errors escape even event events ever every exact example "
    "except exist exit expect extra face fact facts fail failed fails failure fair "
    "fall false family famous fast fault favor favour feature feed feedback feel "
    "feels feet fell felt fetch fewer field fields fifth fifty fight figure file "
    "files fill final finally find finding fine finish finished fire firm first "
    "five fixed fixes flag flags flash flat flight float floor flow flush focus "
    "folder follow font food foot force form format former forms forth forty "
    "forum forward found four fourth frame frames free fresh friday friend friends "
    "from front fruit full fully funny future gain game games gate gather gave "
    "general gets getting girl give given gives glad glass global goes going gold "
    "gone good goods gotten grade grand grant graph grasp grass great green grey "
    "grid ground group grow growth guard guess guest guide habit half hall hand "
    "handle hands hang happen happy hard hardly harm have having head header "
    "health hear heard heart heat heavy held hello help helpful hence here hidden "
    "high higher highly hill hint history hold holder holds hole home honest hook "
    "hope horse host hour hours house however huge human hundred hung hurry hurt "
    "icon idea ideal ideas idle ignore image images impact import improve include "
    "income indeed index info input insert inside install instead intent into "
    "intro invite iron island issue issues item items itself join joined joint "
    "joke judge jump just keep keeps kept keys kick kill kind kinds king kitchen "
    "knew knife knock know known knows label labels lack lady laid land landing "
    "language large larger last late later latest launch layer lead leader leads "
    "leaf leak learn least leave leaves left legal length less lesson letter level "
    "levels library license lies life lift light like likely limit line linear "
    "lines link links list listen lists little live lived lives living load loaded "
    "loader local locate lock locked logic login long longer look looked looking "
    "looks loop loose lose loss lost lots loud love lower luck lunch machine made "
    "mail main major make makes making male manage manual many maps march mark "
    "market marks match maybe meal mean meaning means meant measure media meet "
    "meeting meets member memory menu merge message meta meter method middle might "
    "mile miles milk million mind mine mini minor minus minute minutes mirror miss "
    "missed misses missing mixed mobile mode model models modern modes modify "
    "module moment monday money monitor month months mood more morning most mostly "
    "mother motion motor mount mouse mouth move moved moves moving much multi "
    "music must myself name named names narrow nation native nature near nearly "
    "neat need needed needs neither nerve nested network never newer newly next "
    "nice night nine nobody noise none noon normal north nose note noted notes "
    "nothing notice notify novel number numbers object obtain occur ocean offer "
    "office offset often okay older once ones online only onto open opened opens "
    "option orange order other others ought ours outer output outside over overall "
    "owner owners pack package page pages paid pain paint pair panel paper parent "
    "park parse part parts party pass passed passes past paste patch path paths "
    "pattern pause peak peer pending people percent perfect perform period permit "
    "person phase phone photo phrase pick picked picker picture piece pieces pile "
    "pill pilot pink pipe pitch pixel place places plain plan plane planet plans "
    "plant plate play played player plays please plenty plot plug plus pocket "
    "point points policy polish poll pool poor pop port portal pose position "
    "post posted posts pound pour power prefix press pretty prevent price pride "
    "prime print prior privacy private prize probe problem process produce product "
    "profile profit program project promise prompt proof proper protect proud "
    "prove provide proxy public pull pulled pulse pump punch pure purple purpose "
    "push pushed puts putting puzzle python query queue quick quickly quiet quit "
    "quite quote quotes race radio rail rain raise raised range rank rapid rare "
    "rate rates rather ratio reach react read reader ready real realize really "
    "reason recall recent record recover reduce refer refine refresh refuse region "
    "register reject relate release relevant reload rely remain remark remember "
    "remind remote remove rename render renew repair repeat replace reply report "
    "request require rescue research reset reside resist resolve respect respond "
    "rest restart restore result results resume retail retain retire retry return "
    "reveal review revise reward rhythm rich ride right ring rise risk road rock "
    "role roles roll room rooms root rope rough round route router routine rows "
    "royal rule rules ruler running runs rush safe safely safety said sail sake "
    "salad salary sale sales salt same sample sand save saved saves saving says "
    "scale scan scene schedule scheme school science scope score screen script "
    "scroll search season seat second seconds secret section secure seed seek "
    "seem seems seen segment select self sell send sender sends senior sense sent "
    "sentence separate sequel series serious serve server service session set "
    "sets setting settings settle seven several severe shade shadow shake shall "
    "shape share shared sharp sheet shelf shell shelter shift shine ship shipped "
    "shirt shock shoe shoes shoot shop shore short shortly shot should shoulder "
    "shout show showed shown shows shut side sides sight sign signal signed silent "
    "silver similar simple simply since single sink site sites sitting sixth sixty "
    "size sizes skill skills skin skip skipped skirt sleep slice slide slight slim "
    "slip slot slow slowly small smart smell smile smoke smooth snap snapshot snow "
    "social socket soft software soil sold sole solid solve some somehow someone "
    "something sometime somewhat somewhere song songs soon sorry sort soul sound "
    "sounds soup source sources south space span spare spark speak speaker speech "
    "speed spell spend spent spin spirit split spoke spoken sponsor spot spread "
    "spring sprint square stable stack staff stage stair stake stamp stand standard "
    "star stare start started starts state stated states static station status "
    "stay stayed stays steady steal steam steel steep steer stem step steps stick "
    "still stock stomach stone stood stop stopped stops storage store stored storm "
    "story straight strain strand strange strap stream street strength stress "
    "stretch strict strike string strip stroke strong struck struct struggle stuck "
    "student studio study stuff style subject submit subset subtle succeed success "
    "such sudden suffer sugar suggest suit suite summer summit sunday super supply "
    "support suppose sure surely surface surge surprise surround survey survive "
    "suspect suspend sustain swap swear sweep sweet swim swing switch symbol "
    "syntax system table tables tablet tackle tail take taken takes taking tale "
    "talent talk talked talking tall tank tape target task tasks taste taught tax "
    "teach team teams tear tech tell tells temp temple ten tend tender tennis "
    "tense tent term terms test tested testing tests text than thank thanks that "
    "their theirs them theme then theory there these they thick thin thing things "
    "think thinks third thirty this those though thought thousand thread threat "
    "three threw throat through throw thrown thumb thursday thus tick ticket tide "
    "tidy tied tier tight tile till time timer times tiny tired title today toggle "
    "token tokens told tolerate toll tomorrow tone tongue tonight took tool tools "
    "tooth topic torch tore total touch tough tour toward towards tower town trace "
    "track tracks trade traffic trail train trait transfer transform transit "
    "translate transmit trap trash travel tray treat tree trees trend trial tribe "
    "trick tried tries trigger trim trip triple troop trouble truck true truly "
    "trunk trust truth trying tube tuesday tune tunnel turn turned turns twelve "
    "twenty twice twin twist type typed types typical ugly unable uncle under "
    "undo uneven unfair unfold union unique unit units unity universe unknown "
    "unless unlike unload unlock until unusual update updated upgrade upon upper "
    "upset urban urge usage used useful user users usual utility utter vacant "
    "vague valid valley value values valve vanish vary vast vault vector vendor "
    "venture venue verb verbal verify version versus very vessel veteran video "
    "view views village violate virtual virus visible vision visit visitor visual "
    "vital vivid vocal voice voices void volume vote voter wage wait waited "
    "waiting wake walk walked wall wallet wander want wanted wants warm warn "
    "warning warrant wash waste watch water wave waves weak wealth weapon wear "
    "weather weave website wedding week weekend weekly weeks weigh weight weird "
    "welcome weld well went were west western wet what whatever wheel when where "
    "whereas whether which while whip whisper white whole whom whose wide widely "
    "width wife wild will willing wind window windows wine wing winner winter wire "
    "wired wise wish with withdraw within without witness woke wolf woman women "
    "wonder wood wooden word words wore work worked worker working works world "
    "worry worse worst worth would wound wrap write writer writes written wrong "
    "wrote yard yeah year years yell yellow yesterday yield young your yours "
    "yourself youth zero zone zoom".split()
)


def _strip_accents(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(c for c in decomposed if unicodedata.category(c) != "Mn")


def phonetic_key(word: str) -> str:
    """Compact English-oriented phonetic skeleton for proper-noun matching."""
    s = re.sub(r"[^a-z]", "", _strip_accents(word).lower())
    if not s:
        return ""
    # Common English digraphs & silent prefixes.
    for prefix in ("kn", "gn", "pn", "wr"):
        if s.startswith(prefix) and len(s) > 2:
            s = s[1:]
            break
    s = s.replace("ph", "f").replace("gh", "").replace("ck", "k")
    s = s.replace("qu", "kw").replace("x", "ks")
    s = re.sub(r"dg(?=[eiy])", "j", s)
    s = re.sub(r"c(?=[eiy])", "s", s)
    s = s.replace("c", "k").replace("q", "k")
    s = s.replace("sh", "X").replace("ch", "X").replace("th", "T")
    s = s.replace("z", "s")
    if not s:
        return ""

    # Keep the leading letter (even if a vowel) plus non-vowel consonant skeleton,
    # collapsing adjacent identical symbols and treating y/h/w gently mid-word.
    out = [s[0]]
    for ch in s[1:]:
        if ch in "aeiouyh":
            continue
        if ch != out[-1]:
            out.append(ch)
    return "".join(out)


def _edit_distance(a: str, b: str, limit: int = 3) -> int:
    """Bounded Levenshtein distance (returns ``limit + 1`` when exceeded)."""
    if a == b:
        return 0
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i] + [0] * len(b)
        row_min = i
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            val = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            curr[j] = val
            if val < row_min:
                row_min = val
        if row_min > limit:
            return limit + 1
        prev = curr
    return prev[-1]


def _initial_class(word: str) -> str:
    s = re.sub(r"[^a-z]", "", _strip_accents(word).lower())
    if not s:
        return ""
    c = s[0]
    if c in "aeiouy":
        return "V"
    if c in "ckq":
        return "K"
    if c in "sz":
        return "S"
    if c in "fv":
        return "F"
    if c in "gj":
        return "J"
    return c


def _prepare_terms(terms: Collection[str]) -> list[tuple[str, str, str, str]]:
    """Return deduplicated ``(canonical, folded, pkey, initial_class)`` for eligible terms."""
    seen: set[str] = set()
    prepared: list[tuple[str, str, str, str]] = []
    for raw in terms:
        if not isinstance(raw, str):
            continue
        canonical = raw.strip()
        # Only single-token terms (no spaces) with >= 4 ASCII-ish letters qualify
        # for fuzzy phonetic matching; multi-word phrases stay exact replacements.
        if not canonical or " " in canonical or not re.fullmatch(r"[A-Za-z][A-Za-z0-9'\-\.]*", canonical):
            continue
        letters = re.sub(r"[^a-z]", "", _strip_accents(canonical).lower())
        if len(letters) < 4:
            continue
        fold = canonical.casefold()
        if fold in seen:
            continue
        seen.add(fold)
        pkey = phonetic_key(canonical)
        if len(pkey) < 2:
            continue
        prepared.append((canonical, letters, pkey, _initial_class(canonical)))
    return prepared


def _best_match(
    token: str,
    prepared: list[tuple[str, str, str, str]],
    *,
    allow_common: bool = False,
) -> str | None:
    letters = re.sub(r"[^a-z]", "", _strip_accents(token).lower())
    if len(letters) < 4:
        return None

    # Exact case-insensitive match: preserve distinctive casing (e.g. velora -> Velora, github -> GitHub).
    for canonical, t_letters, _, _ in prepared:
        if letters == t_letters:
            if any(c.isupper() for c in canonical) and token != canonical:
                return canonical
            return None

    # Never fuzzy-replace a known common English word.
    if not allow_common and letters in _COMMON_ENGLISH_WORDS:
        return None

    tok_key = phonetic_key(token)
    tok_init = _initial_class(token)
    if len(tok_key) < 2:
        return None

    best_score: tuple[int, int] | None = None
    best_canonical: str | None = None
    tied = False

    for canonical, t_letters, t_key, t_init in prepared:
        # Never fuzzy-match onto a term that is itself a common lowercase English word.
        if t_letters in _COMMON_ENGLISH_WORDS and canonical.islower():
            continue
        if tok_init != t_init:
            continue

        p_dist = _edit_distance(tok_key, t_key, limit=1)
        if p_dist > 1:
            continue
        if p_dist == 0:
            max_ed = 1 if len(t_letters) <= 4 else min(3, max(2, len(t_letters) // 3))
        else:
            max_ed = 1 if len(t_letters) < 8 else 2
        ed = _edit_distance(letters, t_letters, limit=max_ed)
        if ed > max_ed:
            continue

        score = (p_dist, ed)
        if best_score is None or score < best_score:
            best_score = score
            best_canonical = canonical
            tied = False
        elif score == best_score and best_canonical != canonical:
            tied = True

    if tied:
        return None
    return best_canonical


def apply_phonetic_glossary(text: str, terms: Collection[str]) -> str:
    """Correct phonetically misheard glossary terms in ``text``.

    Handles both single-token mishearings ("Velorra" -> "Velora",
    "Preea" -> "Priya", "Herder" -> "Herdr") and split-word mishearings
    ("super whisper" -> "Superwhisper", "kuber netties" -> "Kubernetes").
    """
    if not text or not terms:
        return text
    prepared = _prepare_terms(terms)
    if not prepared:
        return text

    parts = _PROTECTED_SPAN_RE.split(text)
    for idx in range(0, len(parts), 2):
        seg = parts[idx]
        if not seg:
            continue
        matches = list(_WORD_RE.finditer(seg))
        if not matches:
            continue

        out: list[str] = []
        cursor = 0
        i = 0
        while i < len(matches):
            m = matches[i]
            # Try a split-word pair first (e.g. "super whisper" -> "Superwhisper")
            # when separated only by single whitespace.
            if i + 1 < len(matches):
                m2 = matches[i + 1]
                gap = seg[m.end() : m2.start()]
                if gap == " ":
                    w1 = m.group(0)
                    w2 = m2.group(0)
                    # Do not merge if both words are common English words UNLESS
                    # their concatenation is an EXACT match for a glossary term
                    # (e.g. "super" + "whisper" == "Superwhisper").
                    joined = w1 + w2
                    joined_low = re.sub(r"[^a-z]", "", _strip_accents(joined).lower())
                    exact_joined = any(t_letters == joined_low for _, t_letters, _, _ in prepared)
                    both_common = (
                        w1.lower() in _COMMON_ENGLISH_WORDS
                        and w2.lower() in _COMMON_ENGLISH_WORDS
                    )
                    if exact_joined or not both_common:
                        pair_hit = _best_match(joined, prepared, allow_common=exact_joined)
                        if pair_hit is not None:
                            out.append(seg[cursor : m.start()])
                            out.append(pair_hit)
                            cursor = m2.end()
                            i += 2
                            continue

            token = m.group(0)
            hit = _best_match(token, prepared)
            if hit is not None:
                out.append(seg[cursor : m.start()])
                out.append(hit)
                cursor = m.end()
            i += 1

        out.append(seg[cursor:])
        parts[idx] = "".join(out)

    return "".join(parts)
