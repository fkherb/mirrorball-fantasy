#!/usr/bin/env python3
"""Read DWTS Wikipedia weekly tables, using only the Python standard library.

Examples (--couples is required only when reading couple information):
    python3 dwts_wiki.py --get-weeks --print
    python3 dwts_wiki.py --pre-show --week-tag '#Week_4:_Mariah_Carey_Night' \
        --couples '{"Amber Glenn": "Pasha Pashkov"}' --print

Couples may be a JSON object mapping full celebrity names to full pro names,
or a JSON list of {"star_name": ..., "pro_name": ...} objects. Pass inline JSON
or @filename. Matching uses BOTH first names, ignoring case and accents.

CLI: one JSON document on stdout; --print enables indentation. Errors are JSON
with a nonzero exit code. Python callers: fetch_information(...) returns a dict.
No database writes, scheduling, confirmation logic, or photo processing.

Set DWTS_WIKI_USER_AGENT to identify your deployment with contact information.
"""

import argparse
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path


DEFAULT_PAGE = (
    "https://en.wikipedia.org/wiki/"
    "Dancing_with_the_Stars_(American_TV_series)_season_35"
)
MODES = {"pre-show", "live-show", "post-show", "get-weeks"}
VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}
EMPTY_VALUES = {"", "—", "–", "-", "tba", "tbd", "n/a", "?"}


class WikiError(ValueError):
    """Invalid input, unavailable page, or an unsupported source format."""


@dataclass(eq=False)
class Node:
    tag: str
    attrs: dict = field(default_factory=dict)
    children: list = field(default_factory=list)
    parent: object = None

    def walk(self):
        yield self
        for child in self.children:
            if isinstance(child, Node):
                yield from child.walk()

    def ancestor(self, tag):
        node = self.parent
        while node is not None:
            if node.tag == tag:
                return node
            node = node.parent
        return None

    def text(self):
        # Footnotes and edit controls are not part of names or data values.
        if self.tag in {"sup", "script", "style"} or "mw-editsection" in self.attrs.get("class", "").split():
            return ""
        if self.tag == "br":
            return "\n"
        pieces = [child.text() if isinstance(child, Node) else child
                  for child in self.children]
        return "".join(pieces)


class DocumentParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("document")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs), parent=self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def clean(value):
    return " ".join(value.split())


def normalized(value):
    value = unicodedata.normalize("NFKD", value).casefold()
    return "".join(c for c in value if not unicodedata.combining(c))


def first_name(value):
    words = re.findall(r"[^\W\d_]+(?:[-’'][^\W\d_]+)*", normalized(value))
    return words[0] if words else ""


def normalize_couples(couples):
    if isinstance(couples, dict):
        couples = [{"star_name": star, "pro_name": pro} for star, pro in couples.items()]
    if not isinstance(couples, list) or not couples:
        raise WikiError("Couples must be a nonempty JSON object or list.")
    result, seen = [], set()
    for entry in couples:
        if not isinstance(entry, dict):
            raise WikiError("Each couple must contain star_name and pro_name.")
        pair = {}
        for key in ("star_name", "pro_name"):
            name = entry.get(key)
            if not isinstance(name, str) or len(clean(name).split()) < 2:
                raise WikiError(f"{key} must include both first and last names.")
            pair[key] = clean(name)
        key = (first_name(pair["star_name"]), first_name(pair["pro_name"]))
        if key in seen:
            raise WikiError(f"Ambiguous input: multiple couples have first names {key}.")
        seen.add(key)
        result.append(pair)
    return result


def read_couples(argument):
    try:
        raw = Path(argument[1:]).read_text(encoding="utf-8") if argument.startswith("@") else argument
        return normalize_couples(json.loads(raw))
    except (OSError, json.JSONDecodeError) as exc:
        raise WikiError(f"Cannot read couples JSON: {exc}") from exc


def page_location(page_url):
    parsed = urllib.parse.urlsplit(page_url)
    if parsed.scheme != "https" or parsed.hostname != "en.wikipedia.org" or not parsed.path.startswith("/wiki/"):
        raise WikiError("--page-url must be an https://en.wikipedia.org/wiki/... article URL.")
    title = urllib.parse.unquote(parsed.path[len("/wiki/"):])
    if not title:
        raise WikiError("The Wikipedia article title is missing.")
    return title, "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title, safe="_():,")


def fetch_page(page_url=DEFAULT_PAGE):
    title, _ = page_location(page_url)
    query = urllib.parse.urlencode({
        "action": "parse", "page": title, "prop": "text|revid",
        "format": "json", "formatversion": "2", "redirects": "1", "maxlag": "5",
    })
    request = urllib.request.Request(
        "https://en.wikipedia.org/w/api.php?" + query,
        headers={
            "User-Agent": os.getenv("DWTS_WIKI_USER_AGENT", "DWTSWikiReader/1.0 (personal read-only fantasy tool)"),
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        retry = exc.headers.get("Retry-After")
        suffix = f"; Retry-After: {retry}" if retry else ""
        raise WikiError(f"Wikipedia returned HTTP {exc.code}{suffix}. Retry on a later invocation.") from exc
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        raise WikiError(f"Cannot fetch Wikipedia: {exc}") from exc
    if "error" in data:
        error = data["error"]
        raise WikiError(f"Wikipedia API error {error.get('code')}: {error.get('info')}")
    parsed = data.get("parse", {})
    html = parsed.get("text")
    if isinstance(html, dict):
        html = html.get("*")  # Also accepts formatversion=1 fixtures.
    if not isinstance(html, str) or not html:
        raise WikiError("Wikipedia did not return article HTML.")
    return html, parsed.get("revid")


def heading_level(node):
    return int(node.tag[1]) if re.fullmatch(r"h[1-6]", node.tag) else None


def heading_anchor(node):
    if node.attrs.get("id"):
        return node.attrs["id"]
    return next((child.attrs["id"] for child in node.walk() if child.attrs.get("id")), "")


def weekly_sections(root, source_url):
    nodes = list(root.walk())
    start = next((i for i, n in enumerate(nodes)
                  if heading_level(n) and normalized(clean(n.text())) == "weekly scores"), None)
    if start is None:
        raise WikiError("The article has no 'Weekly scores' section.")
    level = heading_level(nodes[start])
    end = next((i for i in range(start + 1, len(nodes))
                if heading_level(nodes[i]) and heading_level(nodes[i]) <= level), len(nodes))
    weeks = []
    for i in range(start + 1, end):
        node = nodes[i]
        if not heading_level(node):
            continue
        title = clean(node.text())
        match = re.match(r"^Week\s+(\d+)\b", title, re.I)
        anchor = heading_anchor(node)
        if match and anchor:
            stop = next((j for j in range(i + 1, end)
                         if heading_level(nodes[j]) and heading_level(nodes[j]) <= heading_level(node)), end)
            weeks.append({
                "week": int(match.group(1)), "title": title,
                "week_tag": "#" + anchor,
                "url": source_url + "#" + urllib.parse.quote(anchor, safe="_():,"),
                "nodes": nodes[i + 1:stop],
            })
    return weeks


def normalize_tag(tag):
    # Accept #anchor, bare anchor, or the complete article URL with its fragment.
    if "://" in tag:
        tag = urllib.parse.urlsplit(tag).fragment
    return normalized(urllib.parse.unquote(tag.lstrip("#")).replace("_", " ").strip())


def table_grid(table):
    """Expand rowspan/colspan so each data row has its proper couple and result."""
    rows = [n for n in table.walk() if n.tag == "tr" and n.ancestor("table") is table]
    slots = {}
    result = []
    for row_index, row in enumerate(rows):
        col = 0
        for cell in (n for n in row.children if isinstance(n, Node) and n.tag in {"th", "td"}):
            while (row_index, col) in slots:
                col += 1
            try:
                rowspan = int(cell.attrs.get("rowspan", 1))
                colspan = int(cell.attrs.get("colspan", 1))
            except (TypeError, ValueError) as exc:
                raise WikiError("A table has an invalid row or column span.") from exc
            if rowspan == 0:
                rowspan = len(rows) - row_index
            if not 1 <= rowspan <= len(rows) or not 1 <= colspan <= 100:
                raise WikiError("A table has an unsupported row or column span.")
            for r in range(row_index, row_index + rowspan):
                for c in range(col, col + colspan):
                    slots[r, c] = cell
            col += colspan
        width = max((c for r, c in slots if r == row_index), default=-1) + 1
        result.append([slots.get((row_index, c)) for c in range(width)])
    return result


def column_type(cell):
    if cell is None:
        return None
    name = normalized(clean(cell.text())).strip(":")
    if name in {"couple", "couples"}:
        return "couple"
    if name in {"score", "scores"}:
        return "scores"
    if name in {"dance", "dances", "dance type", "style"}:
        return "dance"
    if "music" in name or name in {"song", "songs", "song choice"}:
        return "music"
    if name in {"result", "results", "status"}:
        return "result"
    return None


def field_value(row, columns, field_name):
    cells = []
    for index in columns.get(field_name, []):
        if index < len(row) and row[index] is not None and row[index] not in cells:
            cells.append(row[index])
    value = clean(" ".join(cell.text() for cell in cells))
    return None if normalized(value) in EMPTY_VALUES else value


def pair_key(label):
    names = re.split(r"\s*(?:&|\band\b)\s*", label, maxsplit=1, flags=re.I)
    return (first_name(names[0]), first_name(names[1])) if len(names) == 2 else None


def music_information(raw):
    if raw is None:
        return {"song": None, "artist": None}
    # Theme weeks name the source after the song: '"Zoo" (from Zootopia 2)'.
    source = None
    sourced = re.fullmatch(r'(.*["”])\s*\(\s*from\s+([^)]+)\)\s*(.*)', raw, flags=re.I)
    if sourced:
        raw, source = clean(sourced.group(1) + " " + sourced.group(3)), clean(sourced.group(2))
    # Quotes let a song title itself contain an em dash without becoming an artist.
    quoted = re.fullmatch(r'["“](.*)["”](?:\s*[—–-]\s*(.+))?', raw)
    if quoted:
        song, artist = quoted.groups()
    else:
        pieces = re.split(r"\s+[—–]\s+", raw, maxsplit=1)
        song, artist = pieces[0], pieces[1] if len(pieces) == 2 else None
    info = {"song": clean(song), "artist": clean(artist) if artist else None}
    if source:
        info["source"] = source
    return info


def score_information(raw):
    info = {"scores": None, "total": None, "scores_raw": raw}
    if raw is None:
        return info
    tuples = re.findall(r"\((\s*\d+(?:\.\d+)?(?:\s*,\s*\d+(?:\.\d+)?)+\s*)\)", raw)
    if len(tuples) != 1:
        info["warning"] = "Expected exactly one complete comma-separated judge-score tuple."
        return info
    scores = [float(value.strip()) for value in tuples[0].split(",")]
    if any(not 0 < value <= 10 for value in scores):
        info["warning"] = "A judge score is outside the expected range of 1 through 10."
        return info
    info["scores"] = [int(value) if value.is_integer() else value for value in scores]
    total = re.match(r"^(\d+(?:\.\d+)?)\s*\(", raw)
    if total:
        value = float(total.group(1))
        info["total"] = int(value) if value.is_integer() else value
        if value != sum(scores):
            info["warning"] = "Listed total differs from judge-score sum; may include bonuses."
    return info


NO_ELIMINATION = re.compile(r"\bno elimination (took place|this week|occurred|was held)\b"
                            r"|\bno (couple|couples|one) (was|were) eliminated\b"
                            r"|\bnon-elimination (week|episode|round)\b")


def elimination_information(raw):
    eliminated = None
    if raw:
        text = normalized(raw)
        if re.search(r"\bnot eliminated\b", text):
            eliminated = False
        elif re.search(r"\beliminated\b", text) and not re.search(r"\bsafe\b", text):
            eliminated = True
        elif re.search(r"\bsafe\b", text) and not re.search(r"\beliminated\b", text):
            eliminated = False
    return {"eliminated": eliminated}


TEAM_DANCE = re.compile(r"\(\s*team\s+([^)]+?)\s*\)", re.I)
PAIR_IN_TEXT = re.compile(r"([^\W\d_]+(?:[-’'][^\W\d_]+)*)\s*(?:&|\band\b)\s*([^\W\d_]+(?:[-’'][^\W\d_]+)*)", re.I)


def team_leader(label):
    """The co-host named above a team's couples: "Alfonso Ribeiro Amber & Pasha …" → "Alfonso".
    None when the cell starts with a couple."""
    before = clean(label or "").split("&", 1)[0].split()
    leader = before[:-1]   # the last word before the first "&" is that couple's star
    return first_name(" ".join(leader)).capitalize() if leader else None


def special_kind(dance):
    """team / marathon / relay for a late-season row's Dance text, else None."""
    text = normalized(dance or "")
    if TEAM_DANCE.search(dance or ""):
        return "team"
    if "marathon" in text:
        return "marathon"
    if re.search(r"\brelay\b", text):
        return "relay"
    return None


def match_result(raw):
    text = normalized(raw or "")
    if re.search(r"\bwinners?\b|\bwon\b", text):
        return "winner"
    if re.search(r"\blosers?\b|\blost\b", text):
        return "loser"
    return None


def couple_name(record):
    return {"star_name": record["star_name"], "pro_name": record["pro_name"]}


class CoupleIndex:
    """Known couples by both first names, and by the star's first name when that is unique
    (relay rows can pair a star with a past winner instead of their pro)."""
    def __init__(self, records):
        self.by_pair = {(first_name(r["star_name"]), first_name(r["pro_name"])): r for r in records}
        stars = {}
        for record in records:
            stars.setdefault(first_name(record["star_name"]), []).append(record)
        self.by_star = {name: found[0] for name, found in stars.items() if len(found) == 1}

    def strict(self, label):
        return self.by_pair.get(pair_key(label)) if label else None

    def loose(self, label):
        if not label:
            return None
        found = self.strict(label)
        if found:
            return found
        key = pair_key(label)
        return self.by_star.get(key[0]) if key else None

    def all_in(self, text):
        """Every known couple written as "Star & Pro" inside a team's Couple cell, in order."""
        found = []
        for star, pro in PAIR_IN_TEXT.findall(normalized(text or "")):
            record = self.by_pair.get((first_name(star), first_name(pro)))
            if record and record not in found:
                found.append(record)
        return found


def table_header(grid):
    for i, row in enumerate(grid):
        columns = {}
        for j, cell in enumerate(row):
            kind = column_type(cell)
            if kind:
                columns.setdefault(kind, []).append(j)
        if "couple" in columns and len(columns) >= 2:
            return i, columns
    return None, {}


def parse_information(html, mode, couples=None, week_tag=None, page_url=DEFAULT_PAGE, revision_id=None):
    """Parse supplied HTML into a JSON-serializable dict (also useful for tests).

    Late-season weeks: a couple's rows are its performances in table order (round 1, 2, 3).
    Team dances ("Freestyle (Team Roar)"), marathon rows and the separate dance-off / relay
    table (no Scores column, Winners/Losers) are reported in teams / marathons / matches and
    never as a couple's performance."""
    if mode not in MODES:
        raise WikiError(f"Unsupported mode: {mode}")
    if mode != "get-weeks" or couples is not None:
        couples = normalize_couples(couples)
    _, source_url = page_location(page_url)
    parser = DocumentParser()
    parser.feed(html)
    weeks = weekly_sections(parser.root, source_url)
    result = {"script": "dwts-wiki.py", "mode": mode, "source_url": source_url}
    if mode == "get-weeks":
        result["weeks"] = [{key: week[key] for key in ("week", "week_tag", "url")} for week in weeks]
        return result
    if not isinstance(week_tag, str) or not week_tag.strip():
        raise WikiError("--week-tag is required for pre-show, live-show, and post-show.")
    selected = [week for week in weeks if normalize_tag(week["week_tag"]) == normalize_tag(week_tag)]
    if len(selected) != 1:
        raise WikiError("Week tag not found or ambiguous. Run --get-weeks for valid tags.")
    week = selected[0]
    result.update({"week": week["week"], "week_tag": week["week_tag"], "source_url": week["url"]})
    records = [{**couple, "found": False, "performances": []} for couple in couples]
    index = CoupleIndex(records)
    required = {"pre-show": {"couple", "dance", "music"},
                "live-show": {"couple", "scores"}, "post-show": {"couple", "result"}}[mode]
    recognized = 0
    warnings = []
    teams, marathons, matches = [], {}, []
    tables = []
    for table_index, table in enumerate(n for n in week["nodes"] if n.tag == "table" and n.ancestor("table") is None):
        grid = table_grid(table)
        header_index, columns = table_header(grid)
        if header_index is not None:
            tables.append((table_index, grid, header_index, columns))
    any_scores = any("scores" in columns for _, _, _, columns in tables)

    def is_bonus_table(grid, header_index, columns):
        if "scores" in columns or "result" not in columns:
            return False
        rows = grid[header_index + 1:]
        if any(match_result(field_value(row, columns, "result")) for row in rows):
            return True
        if any(special_kind(field_value(row, columns, "dance")) == "relay" for row in rows):
            return True
        return any_scores

    for table_index, grid, header_index, columns in tables:
        if is_bonus_table(grid, header_index, columns):
            # Dance-offs and relays: consecutive rows sharing a dance and song are one match.
            for row_index, row in enumerate(grid[header_index + 1:], start=header_index + 1):
                record = index.loose(field_value(row, columns, "couple"))
                if record is None:
                    continue
                dance = field_value(row, columns, "dance")
                music = field_value(row, columns, "music")
                current = matches[-1] if matches else None
                if (current is None or current["table_index"] != table_index or current["_dance"] != dance
                        or current["_music"] != music or len(current["couples"]) >= 2):
                    style = re.sub(r"\s*\brelay\b\s*", " ", dance or "", flags=re.I).strip() or None
                    current = {"kind": "relay" if special_kind(dance) == "relay" else "dance_off",
                               "dance": style, **music_information(music), "couples": [],
                               "table_index": table_index, "row_index": row_index, "_dance": dance, "_music": music}
                    matches.append(current)
                current["couples"].append({**couple_name(record),
                                           "result": match_result(field_value(row, columns, "result"))})
            continue
        main_rows = False
        for row_index, row in enumerate(grid[header_index + 1:], start=header_index + 1):
            dance = field_value(row, columns, "dance")
            kind = special_kind(dance)
            label = field_value(row, columns, "couple")
            # Some seasons name the team only by its co-host ("Alfonso Ribeiro" above the couples)
            # with a plain "Freestyle" in the Dance cell: two or more couples in one cell is a team.
            if kind is None and len(index.all_in(label)) >= 2:
                kind = "team"
            if kind == "team":
                named = TEAM_DANCE.search(dance or "")
                if named:
                    name = clean(named.group(1))
                    style = clean(TEAM_DANCE.sub("", dance)) or None
                else:
                    name = team_leader(label)
                    style = clean(dance or "") or None
                score = score_information(field_value(row, columns, "scores"))
                team = {"team_name": (name if normalized(name).startswith("team") else "Team " + name) if name else None,
                        "dance": style, **music_information(field_value(row, columns, "music")),
                        "scores": score["scores"], "total": score["total"], "scores_raw": score["scores_raw"],
                        "couples": [couple_name(r) for r in index.all_in(label)],
                        "table_index": table_index, "row_index": row_index}
                if score.get("warning") and mode == "live-show":
                    warnings.append(f"{team['team_name']}: {score['warning']}")
                if not any((t["team_name"] or t["couples"]) == (team["team_name"] or team["couples"]) for t in teams):
                    teams.append(team)
                continue
            if kind == "marathon":
                record = index.loose(label)
                marathon = marathons.setdefault(normalized(dance), {
                    "title": dance, **music_information(field_value(row, columns, "music")), "couples": [],
                    "table_index": table_index, "row_index": row_index})
                raw = field_value(row, columns, "scores")
                points = int(raw) if raw and re.fullmatch(r"\d{1,2}", raw) else None
                if record and not any(c["star_name"] == record["star_name"] for c in marathon["couples"]):
                    marathon["couples"].append({**couple_name(record), "points": points})
                continue
            if not required <= columns.keys():
                continue
            main_rows = True
            record = index.strict(label)
            if record is None:
                continue
            data = {}
            if mode == "pre-show":
                data["dance"] = dance
                data.update(music_information(field_value(row, columns, "music")))
                # The table's row order is the running order; the importer orders dances by it.
                data["table_index"] = table_index
                data["row_index"] = row_index
            elif mode == "live-show":
                data.update(score_information(field_value(row, columns, "scores")))
                data["dance"] = dance
                data["song"] = music_information(field_value(row, columns, "music"))["song"] if "music" in columns else None
                data["table_index"] = table_index
                data["row_index"] = row_index
                warning = data.pop("warning", None)
                if warning:
                    warnings.append(f"{record['star_name']} and {record['pro_name']}: {warning}")
            else:
                data.update(elimination_information(field_value(row, columns, "result")))
            record["found"] = True
            record["performances"].append(data)
        if main_rows or required <= columns.keys():
            recognized += 1
    # No result column at all, but the week's text says nobody went home: every couple is safe.
    if mode == "post-show" and not recognized:
        section_text = normalized(clean(" ".join(node.text() for node in week["nodes"] if node.tag in {"p", "div", "ul", "dl"})))
        if NO_ELIMINATION.search(section_text):
            result["no_elimination"] = True
            for record in records:
                record["found"] = True
                record["performances"] = [{"eliminated": False}]
            recognized = 1
    for match in matches:
        match.pop("_dance", None)
        match.pop("_music", None)
    result["couples"] = records
    result["teams"] = teams
    result["matches"] = matches
    result["marathons"] = list(marathons.values())
    result["warnings"] = warnings
    if not recognized:
        result["warnings"].append("No table with the required headings is available in this week section.")
    return result


def _letters(value):
    return re.sub(r"[^a-z]+", "", normalized(clean(value or "")))


def map_rounds(result, week_dances):
    """Late-season weeks: decide which Wikipedia row belongs to which of a couple's dances.

    week_dances: [{dance_id, star_name, pro_name, round, round_label, dance_type, song_title}].
    Adds by_dance {dance_id: performance or None} to each couple. Rows are matched by an
    already-known style or song, then "Freestyle" rows to a Freestyle round, then the rest
    in table order (skipping instant rounds, which only appear on the night). More rows than
    rounds is left unmapped and reported in errors, never guessed."""
    mode = result.get("mode")
    errors = result.setdefault("errors", [])
    grouped = {}
    for dance in week_dances or []:
        grouped.setdefault((dance.get("star_name"), dance.get("pro_name")), []).append(dance)
    for record in result.get("couples", []):
        dances = sorted(grouped.get((record["star_name"], record["pro_name"]), []), key=lambda d: d.get("round") or 1)
        if not dances:
            continue
        perfs = record.get("performances") or []
        if mode == "post-show":
            record["by_dance"] = {d["dance_id"]: (perfs[0] if perfs else None) for d in dances}
            continue
        assigned, free = {}, list(range(len(perfs)))
        for i in list(free):
            perf = perfs[i]
            style, song = _letters(perf.get("dance")), _letters(perf.get("song"))
            hits = [d for d in dances if d["dance_id"] not in assigned and (
                (style and style == _letters(d.get("dance_type"))) or (song and song == _letters(d.get("song_title"))))]
            if len(hits) == 1:
                assigned[hits[0]["dance_id"]] = perf
                free.remove(i)
        for i in list(free):
            if "freestyle" in normalized(perfs[i].get("dance") or ""):
                hits = [d for d in dances if d["dance_id"] not in assigned and "freestyle" in normalized(d.get("round_label") or "")]
                if len(hits) == 1:
                    assigned[hits[0]["dance_id"]] = perfs[i]
                    free.remove(i)
        rest = [d for d in dances if d["dance_id"] not in assigned]
        if free:
            # A couple's rows are in the order they danced, so with fewer rows than rounds (later
            # dances not announced yet) the rows fill the earliest rounds, instant rounds last.
            named = [d for d in rest if "instant" not in normalized(d.get("round_label") or "")]
            target = (rest if len(free) == len(rest) else named if len(free) == len(named)
                      else named[:len(free)] if len(free) < len(named) else None)
            if target is None:
                for d in rest:
                    errors.append({"dance_id": d["dance_id"], "error":
                        f"Couldn't tell which Wikipedia row is dance {d.get('round') or 1} for {record['star_name']}; enter it by hand"})
            else:
                for i, d in zip(free, target):
                    assigned[d["dance_id"]] = perfs[i]
        record["by_dance"] = {d["dance_id"]: assigned.get(d["dance_id"]) for d in dances}
    return result


def map_specials(result, week_specials, week_couples, formats=()):
    """Team dances, dance-offs, relays and marathons from Wikipedia, matched to the week's
    existing team / bonus dances (dance_id) or left for the importer to create (dance_id None).

    week_specials: [{dance_id, kind, bonus_kind, team_name, name, couples: [partnership_id]}]
    week_couples: [{partnership_id, star_name, pro_name}]"""
    ids = {(c["star_name"], c["pro_name"]): c["partnership_id"] for c in week_couples or []}
    specials = []
    existing = week_specials or []
    formats = set(formats or ())

    def pids(couples):
        return [ids[(c["star_name"], c["pro_name"])] for c in couples if (c["star_name"], c["pro_name"]) in ids]

    def team_key(name):
        return re.sub(r"^team", "", _letters(name))

    for team in result.get("teams", []):
        couples = pids(team["couples"])
        found = [s for s in existing if s["kind"] == "team" and (
            team_key(s.get("team_name")) == team_key(team["team_name"]) or (couples and set(s.get("couples") or []) == set(couples)))]
        specials.append({"dance_id": found[0]["dance_id"] if len(found) == 1 else None, "kind": "team", "bonus_kind": None,
                         "team_name": team["team_name"], "name": None, "dance": team["dance"], "song": team["song"],
                         "artist": team["artist"], "scores": team["scores"], "total": team["total"],
                         "couples": [{"partnership_id": p} for p in couples],
                         "key": "team:" + team_key(team["team_name"])})
    for match in result.get("matches", []):
        kind = match["kind"]
        if kind == "dance_off" and "relay" in formats and "dance_off" not in formats:
            kind = "relay"
        couples = [{"partnership_id": ids[(c["star_name"], c["pro_name"])], "result": c["result"]}
                   for c in match["couples"] if (c["star_name"], c["pro_name"]) in ids]
        pair = sorted(c["partnership_id"] for c in couples)
        found = [s for s in existing if s["kind"] == "bonus" and s.get("bonus_kind") == kind and sorted(s.get("couples") or []) == pair]
        winner = [c["partnership_id"] for c in couples if c["result"] == "winner"]
        specials.append({"dance_id": found[0]["dance_id"] if len(found) == 1 else None, "kind": "bonus", "bonus_kind": kind,
                         "team_name": None, "name": None, "dance": match["dance"], "song": match["song"],
                         "artist": match["artist"], "couples": couples,
                         "winner": winner[0] if len(winner) == 1 and len(couples) == 2 else None,
                         "key": kind + ":" + ",".join(pair)})
    for marathon in result.get("marathons", []):
        couples = [{"partnership_id": ids[(c["star_name"], c["pro_name"])], "points": c["points"]}
                   for c in marathon["couples"] if (c["star_name"], c["pro_name"]) in ids]
        found = [s for s in existing if s["kind"] == "bonus" and s.get("bonus_kind") == "marathon"]
        specials.append({"dance_id": found[0]["dance_id"] if len(found) == 1 else None, "kind": "bonus",
                         "bonus_kind": "marathon", "team_name": None, "name": marathon["title"], "dance": None,
                         "song": marathon["song"], "artist": marathon["artist"], "couples": couples,
                         "key": "marathon:" + _letters(marathon["title"])})
    result["specials"] = specials
    return result


def fetch_information(mode, couples=None, week_tag=None, page_url=DEFAULT_PAGE):
    """Fetch Wikipedia once and return a dict; never print or write to a database."""
    if mode not in MODES:
        raise WikiError(f"Unsupported mode: {mode}")
    if mode != "get-weeks" or couples is not None:
        couples = normalize_couples(couples)
    if mode != "get-weeks" and not week_tag:
        raise WikiError("week_tag is required for this mode.")
    html, revision_id = fetch_page(page_url)
    return parse_information(html, mode, couples, week_tag, page_url, revision_id)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_mutually_exclusive_group(required=True)
    for mode, description in (
        ("pre-show", "Get dance types, songs, and explicitly listed artists."),
        ("live-show", "Get individual judge scores and listed totals."),
        ("post-show", "Get elimination flags."),
        ("get-weeks", "List week headings/tags under Weekly scores."),
    ):
        modes.add_argument("--" + mode, dest="mode", action="store_const", const=mode, help=description)
    parser.add_argument("--couples", metavar="JSON_OR_@FILE", help="Full-name couples JSON, inline or @filename; required except with --get-weeks.")
    parser.add_argument("--week-tag", help="Week fragment, with or without #; required except with --get-weeks.")
    parser.add_argument("--print", dest="pretty", action="store_true", help="Pretty-print JSON. Without this flag, stdout still contains compact JSON.")
    parser.add_argument("--page-url", default=DEFAULT_PAGE, help="Wikipedia article URL (default: American season 35).")
    args = parser.parse_args(argv)
    try:
        if args.mode != "get-weeks" and args.couples is None:
            raise WikiError("--couples is required for pre-show, live-show, and post-show.")
        if args.mode != "get-weeks" and not args.week_tag:
            raise WikiError("--week-tag is required for this mode.")
        couples = read_couples(args.couples) if args.couples is not None else None
        result = fetch_information(args.mode, couples, args.week_tag, args.page_url)
        status = 0
    except WikiError as exc:
        result = {"script": "dwts-wiki.py", "error": str(exc), "mode": args.mode}
        status = 1
    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None,
                     separators=None if args.pretty else (",", ":")))
    return status


if __name__ == "__main__":
    sys.exit(main())
