#!/usr/bin/env python3
"""Write unicode_tables.odin and the tables/*.bin it loads: Oniguruma's character properties and simple case folding as jq 1.8.2 matches them.

Each table is the code points a property holds, read from jq itself: a string of every code point but the
surrogates, matched with `\\p{NAME}+` under "g". So `\\p{...}`, \\w, \\d, \\s and the POSIX brackets hold what
Oniguruma's own tables hold (Unicode 16.0 in Oniguruma 6.9.10), which neither Python's unicodedata (no
scripts) nor core:unicode (Unicode 17) gives. The names are those Oniguruma's name table holds, as it
compares them (lower case, no space, `_` or `-`): the strings of its library that jq accepts as `\\p{...}`.
The case folds are read alike: the characters `(?i)\\x{...}` matches alone, for each cased character.

Run from the repository root, with jq 1.8.2 on PATH and its libonig:
    python3 cmd/stury/regex/unicode_tables.py [/opt/homebrew/opt/oniguruma/lib/libonig.dylib]
"""
import json
import pathlib
import re
import struct
import subprocess
import sys

OUT = pathlib.Path(__file__).with_name("unicode_tables.odin")
BLOBS = OUT.with_name("tables")
LIBONIG = sys.argv[1] if len(sys.argv) > 1 else "/opt/homebrew/opt/oniguruma/lib/libonig.dylib"

# The types stury names apart from `\p{...}`: the escapes and the POSIX brackets, by the pattern that
# matches one character of each.
# Within a bracket class, \w is Oniguruma's POSIX word type, which lacks the digits ²³¹ and fractions ¼½¾.
TYPES = {"word": r"\w", "class_word": r"[\w]", "digit": r"\d", "space": r"\s",
         "regional": r"\p{regionalindicator}", "pictographic": r"\p{extendedpictographic}"}

# Oniguruma's grapheme cluster break classes, which no \p{...} names, as \X shows them: the characters c for
# which before + c + after is one cluster (for gcb_alone, is not).
GRAPHEME = {
    "gcb_join": ([0x61], []),  # a × c: Extend, ZWJ and SpacingMark (GB9, GB9a)
    "gcb_prepend": ([], [0x61]),  # c × a: Prepend (GB9b)
    "gcb_alone": ([], [0x301]),  # c ÷ U+0301: Control, CR and LF (GB4)
    "gcb_extend": ([0x1F600], [0x200D, 0x1F600]),  # 😀 c ZWJ × 😀: Extend (GB11)
}
CLUSTERS = r"""
.[] as [$key, $before, $after] | {key: $key, value: [range(0; 1114112) | select(. < 55296 or . > 57343)
  | select([$before[], ., $after[]] | implode | test("\\A\\X\\z"))]}
"""
POSIX = "alnum alpha ascii blank cntrl digit graph lower print punct space upper word xdigit".split()

# Every code point a string holds, in order; a match's character offset past the surrogates is 0x800 on.
SCAN = r"""
([range(0; 1114112) | select(. < 55296 or . > 57343)] | implode) as $all
| .[] as [$key, $pattern] | {key: $key, value: [$all | match($pattern + "+"; "g") | [.offset, .offset + .length - 1]
  | map(if . >= 55296 then . + 2048 else . end)]}
"""

# The characters `(?i)\x{c}` matches alone, for each cased character c, in a text of them all apart.
FOLDS = r"""
.text as $text | .chars[] as [$c, $pattern] | [$c, [$text | match($pattern; "g") | .string | explode
  | select(length == 1) | .[0]]]
"""


def jq(program, data):
    p = subprocess.run(["jq", "-c", program], input=json.dumps(data).encode(), capture_output=True, check=True)
    return [json.loads(line) for line in p.stdout.decode().splitlines()]


def grapheme_classes():
    one = {e["key"]: set(e["value"]) for e in jq(CLUSTERS, [[k, b, a] for k, (b, a) in GRAPHEME.items()])}
    one["gcb_alone"] = {c for c in range(0x110000) if not 0xD800 <= c <= 0xDFFF} - one["gcb_alone"]
    def ranges(points):
        out = []
        for c in sorted(points):
            if out and out[-1][1] == c - 1:
                out[-1][1] = c
            else:
                out.append([c, c])
        return out
    return {"type " + k: ranges(v) for k, v in one.items()}


def fold_orbits(found):
    """Each character that folds to others, the next of its orbit (the characters it matches under (?i)), and
    the orbit's fold: its lower case ASCII letter when it holds one, as the ASCII fast path folds, else its
    least."""
    cased = sorted({c for name in ("cased", "changeswhencasemapped", "changeswhencasefolded")
                    for lo, hi in found[name] for c in range(lo, hi + 1)})
    text = "\n".join(map(chr, cased))
    matched = dict(jq(FOLDS, {"text": text, "chars": [[c, f"(?i)\\x{{{c:X}}}"] for c in cased]}))
    orbits = {}
    for c in cased:
        orbit = frozenset(matched[c]) | {c}
        for d in orbit:
            assert frozenset(matched[d]) | {d} == orbit, f"folding is no equivalence at {c:X}, {d:X}"
        orbits[c] = sorted(orbit)
    folds = []
    for c, orbit in orbits.items():
        if len(orbit) > 1:
            ascii = [d for d in orbit if d < 0x80]
            least = ord(chr(min(ascii)).lower()) if ascii else orbit[0]
            folds.append((c, orbit[(orbit.index(c) + 1) % len(orbit)], least))
    return folds


def multi_folds(folds):
    """Each character Unicode's full case folding makes two or three (Python's str.casefold, checked against
    jq both ways), with the string's characters as stury folds them."""
    multi = [(c, chr(c).casefold()) for c in range(0x110000)
             if not 0xD800 <= c <= 0xDFFF and len(chr(c).casefold()) > 1]
    hexes = lambda s: "".join(f"\\x{{{ord(x):X}}}" for x in s)
    checks = [[f, chr(c), f"^(?i:\\x{{{c:X}}})$", f"^(?i:{hexes(f)})$"] for c, f in multi]
    agree = jq(".[] as [$f, $c, $p, $q] | ($f | test($p)) and ($c | test($q))", checks)
    assert all(agree), [hex(c) for (c, _), ok in zip(multi, agree) if not ok]
    canon = {c: f for c, _, f in folds}
    return [(c, [canon.get(ord(x), ord(x)) for x in f] + [0] * (3 - len(f))) for c, f in multi]


def main():
    v = subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip()
    if v != "jq-1.8.2":
        sys.exit(f"needs jq 1.8.2 on PATH, found {v or 'none'}")
    words = sorted(set(re.findall(rb"(?<=\0)[a-z0-9]+(?=\0)", open(LIBONIG, "rb").read())))
    words = [w.decode() for w in words]
    names = jq(r'.[] as $n | select(try ("" | test("\\p{" + $n + "}") | true) catch false) | $n', words)
    patterns = [[n, r"\p{" + n + "}"] for n in names]
    patterns += [["type " + k, p] for k, p in TYPES.items()]
    patterns += [["posix " + k, f"[[:{k}:]]"] for k in POSIX]
    found = {e["key"]: e["value"] for e in jq(SCAN, patterns)} | grapheme_classes()
    # Two types in_table derives rather than stores (TABLE_CLASS_WORD, TABLE_GCB_EXTEND in unicode.odin).
    points = lambda key: {c for lo, hi in found[key] for c in range(lo, hi + 1)}
    assert points("type class_word") == points("posix word") == points("type word") - {0xB2, 0xB3, 0xB9, 0xBC, 0xBD, 0xBE}
    assert points("type gcb_extend") == points("graphemeextend") | set(range(0x1F3FB, 0x1F400))
    derived = {"class_word", "gcb_extend"}

    tables, index = [], {}
    def table_of(key):
        ranges = json.dumps(found[key])
        if ranges not in index:
            index[ranges] = len(tables)
            tables.append(found[key])
        return index[ranges]
    folds = fold_orbits(found)
    multi = multi_folds(folds)
    named = [(n, table_of(n)) for n in names]
    types = {k: table_of("type " + k) for k in [*TYPES, *GRAPHEME] if k not in derived}
    types["grapheme_extend"] = table_of("graphemeextend")
    posix = [(k, "TABLE_CLASS_WORD" if k == "word" else table_of("posix " + k)) for k in POSIX]

    # Each range is one u32, `lo << SPAN_BITS | (hi - lo)`, so a table is searched by lo in place; a range
    # longer than SPAN_BITS spans is split. Each fold is one u64, `c << 2 * FOLD_BITS | next << FOLD_BITS | fold`.
    SPAN_BITS, FOLD_BITS = 11, 21
    def packed(t):
        for lo, hi in t:
            while hi - lo >= 1 << SPAN_BITS:
                yield lo << SPAN_BITS | (1 << SPAN_BITS) - 1
                lo += 1 << SPAN_BITS
            yield lo << SPAN_BITS | hi - lo
    packed_tables = [list(packed(t)) for t in tables]
    starts, at = [], 0
    for t in packed_tables:
        starts.append(at)
        at += len(t)
    starts.append(at)
    assert at < 1 << 16 and len(tables) < 1 << 16
    assert all(x < 1 << FOLD_BITS for f in folds for x in f)

    # The tables as little-endian blobs the package `#load`s; the names one string, each ended by a NUL.
    BLOBS.mkdir(exist_ok=True)
    blobs = {
        "ranges": struct.pack(f"<{at}I", *(x for t in packed_tables for x in t)),
        "tables": struct.pack(f"<{len(starts)}H", *starts),
        "names": b"".join(n.encode() + b"\0" for n, _ in named),
        "name_tables": struct.pack(f"<{len(named)}H", *(t for _, t in named)),
        "folds": struct.pack(f"<{len(folds)}Q", *(c << 2 * FOLD_BITS | n << FOLD_BITS | f for c, n, f in folds)),
        "multi_folds": struct.pack(f"<{4 * len(multi)}I", *(x for c, f in multi for x in (c, *f))),
    }
    for name, data in blobs.items():
        (BLOBS / f"{name}.bin").write_bytes(data)
    out = [
        "package regex",
        "",
        "// Generated by unicode_tables.py from jq 1.8.2 and Oniguruma 6.9.10 (Unicode 16.0). Do not edit.",
        "// The tables are Oniguruma's and the Unicode Character Database's: see THIRD_PARTY_NOTICES.",
        "// Table k holds the code points PROPERTY_RANGES[PROPERTY_TABLES[k]:PROPERTY_TABLES[k + 1]] give, in",
        "// order, each inclusive [lo, hi] as `lo << RANGE_SPAN_BITS | (hi - lo)`: a range longer than",
        "// RANGE_SPAN_BITS spans is split.",
        "",
        *[f"TABLE_{k.upper()} :: {t}" for k, t in types.items()],
        "",
        f"RANGE_SPAN_BITS :: {SPAN_BITS}",
        '@(rodata) PROPERTY_RANGES := #load("tables/ranges.bin", []u32)',
        '@(rodata) PROPERTY_TABLES := #load("tables/tables.bin", []u16)',
        "",
        "// The `\\p{...}` names in order, as Oniguruma compares them, each ended by a NUL, and each one's table.",
        'PROPERTY_NAMES :: #load("tables/names.bin", string)',
        '@(rodata) PROPERTY_NAME_TABLES := #load("tables/name_tables.bin", []u16)',
        "",
        "// The POSIX brackets `[:name:]` and their tables.",
        "@(rodata)",
        "POSIX_NAMES := [?]string {" + " ".join(f'"{k}",' for k, _ in posix) + "}",
        "",
        "@(rodata)",
        "POSIX_TABLES := [?]u16 {" + " ".join(f"{t}," for _, t in posix) + "}",
        "",
        "// Each character (?i) matches others to, in order, as `c << 2 * FOLD_BITS | next << FOLD_BITS | fold`:",
        "// the character, the next of those it matches (each one's next in turn gives them all), and the one",
        "// they all fold to.",
        f"FOLD_BITS :: {FOLD_BITS}",
        '@(rodata) FOLDS := #load("tables/folds.bin", []u64)',
        "",
        "// Each character (?i) also matches a string of two or three to, in order, and the string's characters",
        "// folded (0 after two).",
        '@(rodata) MULTI_FOLDS := #load("tables/multi_folds.bin", [][4]u32)',
        "",
    ]
    OUT.write_text("\n".join(out))
    print(f"{OUT}: {len(names)} names, {len(tables)} tables, {at} ranges, {len(folds)} folding characters")


if __name__ == "__main__":
    main()
