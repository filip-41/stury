#!/usr/bin/env python3
"""Write unicode_tables.odin and the tables/*.bin it loads: the character properties and simple case folding of
Unicode 17.0, under Oniguruma's names as jq 1.8.2 reads them and ECMA-262's as Node's RegExp does.

The names are those Oniguruma's name table holds, as it compares them (lower case, no space, `_` or `-`): the strings
of its library that jq accepts as `\\p{...}`. Each one's characters are its Unicode 17.0 property: the
General_Category, Script or binary property Node's RegExp gives (Unicode 17.0 in Node 22), else the binary property of
PropList.txt or DerivedCoreProperties.txt. Oniguruma's POSIX brackets, its \\w, \\d and \\s and its names that are
none of these are formulas over those properties, each checked to give Oniguruma's own table (Unicode 16.0 in 6.9.10,
read from jq: a string of every code point but the surrogates, matched with `\\p{NAME}+` under "g") from Oniguruma's
tables of its terms. A block keeps Oniguruma's range, as a block's range does not move. The grapheme cluster break
classes \\X needs are read from Node's Intl.Segmenter as from jq's \\X. Case folding is CaseFolding.txt's simple
folding, which jq's `(?i)` matches on every character Unicode 16 assigned; the folds to two or three characters are
its full folding. The script prints each table that differs from Oniguruma's on a character Unicode 16 assigned with
the same General_Category, which are Unicode 17's changes.

The names ECMA-262 takes in `\\p{...}` are those PropertyValueAliases.txt spells that Node accepts, each on the
characters Node gives it. A table the two sides hold alike is stored once.

Run from the repository root, with jq 1.8.2 and Node on PATH and jq's libonig, and directories holding the Unicode
17.0 files PropertyValueAliases.txt, PropList.txt, DerivedCoreProperties.txt and CaseFolding.txt (fetched from
unicode.org when no directory holds one):
    python3 core/regex/unicode_tables.py [/opt/homebrew/opt/oniguruma/lib/libonig.dylib [UCD_DIRECTORY...]]
"""
import json
import pathlib
import re
import struct
import subprocess
import sys
import urllib.request

OUT = pathlib.Path(__file__).with_name("unicode_tables.odin")
BLOBS = OUT.with_name("tables")
LIBONIG = sys.argv[1] if len(sys.argv) > 1 else "/opt/homebrew/opt/oniguruma/lib/libonig.dylib"
UCD_DIRECTORIES = sys.argv[2:]
UCD_URL = "https://www.unicode.org/Public/17.0.0/ucd/"

EVERY = frozenset(c for c in range(0x110000) if not 0xD800 <= c <= 0xDFFF)
# Within a bracket class, \w is Oniguruma's POSIX word type, which lacks the digits ²³¹ and fractions ¼½¾.
SUPERSCRIPTS = {0xB2, 0xB3, 0xB9, 0xBC, 0xBD, 0xBE}

# The types stury names apart from `\p{...}`: the escapes and the POSIX brackets, by the pattern that
# matches one character of each.
TYPES = {"word": r"\w", "class_word": r"[\w]", "digit": r"\d", "space": r"\s",
         "regional": r"\p{regionalindicator}", "pictographic": r"\p{extendedpictographic}"}
POSIX = "alnum alpha ascii blank cntrl digit graph lower print punct space upper word xdigit".split()


# Oniguruma's tables that are no Unicode property, each from `p`, which gives a property's characters by its Oniguruma
# name.
def graph(p):
    return EVERY - p("whitespace") - p("cc") - p("cn") - p("cs")


def posix_word(p):
    return p("alphabetic") | p("m") | p("nd") | p("pc")


FORMULAS = {
    "alnum": lambda p: p("alphabetic") | p("nd"),
    "blank": lambda p: p("zs") | {0x09},
    "graph": graph,
    "print": lambda p: graph(p) | p("zs"),
    "newline": lambda p: {0x0A},
    "posixpunct": lambda p: p("p") | p("s"),
    "space": lambda p: p("whitespace"),
    "word": lambda p: posix_word(p) | SUPERSCRIPTS,
    "xdigit": lambda p: set(map(ord, "0123456789ABCDEFabcdef")),
}
FORMULAS |= {"posix " + k: FORMULAS[k] for k in ("alnum", "blank", "graph", "print", "space", "xdigit")}
FORMULAS |= {
    "posix alpha": lambda p: p("alphabetic"),
    "posix ascii": lambda p: set(range(0x80)),
    "posix cntrl": lambda p: p("cc"),
    "posix digit": lambda p: p("nd"),
    "posix lower": lambda p: p("lowercase"),
    "posix punct": FORMULAS["posixpunct"],
    "posix upper": lambda p: p("uppercase"),
    "posix word": posix_word,
    "type word": FORMULAS["word"],
    "type class_word": posix_word,
    "type digit": lambda p: p("nd"),
    "type space": lambda p: p("whitespace"),
    "type regional": lambda p: p("regionalindicator"),
    "type pictographic": lambda p: p("extendedpictographic"),
}
GENERAL_CATEGORIES = "lu ll lt lm lo mn mc me nd nl no pc pd ps pe pi pf po sm sc sk so zs zl zp cc cf cs co cn".split()

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
NODE_CLUSTERS = r"""
const seg = new Intl.Segmenter("en", {granularity: "grapheme"}), out = {};
for (const [key, before, after] of JSON.parse(require("fs").readFileSync(0, "utf8"))) {
  out[key] = [];
  for (let c = 0; c < 0x110000; c++) {
    if (c >= 0xD800 && c <= 0xDFFF) continue;
    const segments = seg.segment(String.fromCodePoint(...before, c, ...after))[Symbol.iterator]();
    segments.next();
    if (segments.next().done) out[key].push(c);
  }
}
console.log(JSON.stringify(out));
"""

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

# Oniguruma's message for each error code (*ERROR{n}) may end a search with, but those it has none for.
ERRORS = r"""
range(-600; 0) as $n | "a" | try (test("(*ERROR{\($n)})") | empty) catch "\($n) \(ltrimstr("Regex failure: "))"
  | select(endswith(" undefined error code") | not)
"""


def jq(program, data):
    p = subprocess.run(["jq", "-c", program], input=json.dumps(data).encode(), capture_output=True, check=True)
    return [json.loads(line) for line in p.stdout.decode().splitlines()]


def ucd(name):
    """The lines of a Unicode 17.0 file, from the first directory that holds it, else from unicode.org."""
    for d in UCD_DIRECTORIES:
        if (path := pathlib.Path(d, name)).exists():
            text = path.read_text()
            break
    else:
        text = urllib.request.urlopen(UCD_URL + name).read().decode()
    assert re.match(rf"# {name[:-4]}-17\.0\.0\.txt", text), f"{name} is not Unicode 17.0's"
    return text.splitlines()


def ucd_fields(name):
    """Each line of a Unicode 17.0 file that holds data: the characters it names and its other fields."""
    for line in ucd(name):
        if data := line.split("#")[0].strip():
            fields = [f.strip() for f in data.split(";")]
            lo, _, hi = fields[0].partition("..")
            yield range(int(lo, 16), int(hi or lo, 16) + 1), fields[1:]


def points(ranges):
    return {c for lo, hi in ranges for c in range(lo, hi + 1)}


def ranges_of(chars):
    out = []
    for c in sorted(chars):
        if out and out[-1][1] == c - 1:
            out[-1][1] = c
        else:
            out.append([c, c])
    return out


def grapheme_classes(onig):
    """The grapheme cluster break classes, jq's (Oniguruma's Unicode) with `onig`, else Node's."""
    tests = [[k, b, a] for k, (b, a) in GRAPHEME.items()]
    if onig:
        one = {e["key"]: set(e["value"]) for e in jq(CLUSTERS, tests)}
    else:
        p = subprocess.run(["node", "-e", NODE_CLUSTERS], input=json.dumps(tests).encode(), capture_output=True, check=True)
        one = {k: set(v) for k, v in json.loads(p.stdout).items()}
    one["gcb_alone"] = EVERY - one["gcb_alone"]
    return {"type " + k: v for k, v in one.items()}


def case_folding():
    """CaseFolding.txt's simple folding, each character to the one it folds to, and its full folding to two or three."""
    simple, full = {}, {}
    for chars, (status, to, *_) in ucd_fields("CaseFolding.txt"):
        to = [int(x, 16) for x in to.split()]
        if status in "CS":
            simple[chars[0]] = to[0]
        if status == "F":
            full[chars[0]] = to
    return simple, full


def fold_orbits(onig, simple):
    """Each character that folds to others, the next of its orbit (the characters it matches under (?i)), and
    the orbit's fold: its lower case ASCII letter when it holds one, as the ASCII fast path folds, else its
    least. An orbit is the characters simple folding takes to one, which are those jq's (?i) matches alike on every
    character Unicode 16 assigned."""
    cased = sorted({c for name in ("cased", "changeswhencasemapped", "changeswhencasefolded") for c in onig[name]})
    text = "\n".join(map(chr, cased))
    matched = dict(jq(FOLDS, {"text": text, "chars": [[c, f"(?i)\\x{{{c:X}}}"] for c in cased]}))
    classes = {}
    for c, to in simple.items():
        classes.setdefault(to, {to}).add(c)
    orbits = {c: sorted(orbit) for orbit in classes.values() for c in orbit}
    assigned = EVERY - onig["cn"]
    for c in cased:
        assert set(matched[c]) | {c} == set(orbits.get(c, [c])) & assigned, f"jq folds {c:X} otherwise"
    folds = []
    for c, orbit in sorted(orbits.items()):
        ascii = [d for d in orbit if d < 0x80]
        least = ord(chr(min(ascii)).lower()) if ascii else orbit[0]
        folds.append((c, orbit[(orbit.index(c) + 1) % len(orbit)], least))
    return folds


def multi_folds(onig, full, folds):
    """Each character full case folding makes two or three, checked against jq both ways where Unicode 16 assigned
    it, with the string's characters as stury folds them."""
    multi = sorted((c, f) for c, f in full.items() if len(f) > 1)
    hexes = lambda f: "".join(f"\\x{{{x:X}}}" for x in f)
    checks = [["".join(map(chr, f)), chr(c), f"^(?i:\\x{{{c:X}}})$", f"^(?i:{hexes(f)})$"] for c, f in multi
              if c not in onig["cn"]]
    agree = jq(".[] as [$f, $c, $p, $q] | ($f | test($p)) and ($c | test($q))", checks)
    assert all(agree), [c for (_, c, _, _), ok in zip(checks, agree) if not ok]
    canon = {c: f for c, _, f in folds}
    return [(c, [canon.get(x, x) for x in f] + [0] * (3 - len(f))) for c, f in multi]


# The characters of each \p{...} spelling Node's RegExp takes under "u", as SCAN gives them.
NODE_SCAN = r"""
const all = [], out = {};
for (let c = 0; c < 0x110000; c++) if (c < 0xD800 || c > 0xDFFF) all.push(String.fromCodePoint(c));
const text = all.join("");
for (const name of JSON.parse(require("fs").readFileSync(0, "utf8"))) {
  let re;
  try { re = new RegExp("\\p{" + name + "}+", "gu"); } catch { continue; }
  out[name] = [...text.matchAll(re)].map(m => [m[0].codePointAt(0), [...m[0]].pop().codePointAt(0)]);
}
console.log(JSON.stringify(out));
"""


def property_aliases():
    """Each `\\p{...}` spelling ECMA-262 may take, General_Category values bare or after `gc=`, scripts after `sc=` and
    `scx=` and binary properties bare, with the aliases of the value or property it names, long name first."""
    aliases, prop = {}, None
    for line in ucd("PropertyValueAliases.txt"):
        if m := re.match(r"# (\w+) \((\w+)\)$", line):
            prop = m.groups()
        fields = [f.strip() for f in line.split("#")[0].split(";")]
        if fields[0] in ("gc", "sc"):
            aliases |= {f"{fields[0]}={v}": fields[2:3] + fields[1:2] + fields[3:] for v in fields[1:]}
            if fields[0] == "sc":
                aliases |= {f"scx={v}": fields[2:3] + fields[1:2] + fields[3:] for v in fields[1:]}
        elif prop and fields[0] == prop[1] and fields[1] == "N":
            aliases |= {v: list(prop) for v in prop}
    return aliases | {v: [v] for v in ("Any", "ASCII", "Assigned")}


def node_properties(aliases):
    """The characters Node's RegExp gives each spelling it takes, and Node's Unicode version."""
    p = subprocess.run(["node", "-e", NODE_SCAN], input=json.dumps([*aliases]).encode(), capture_output=True,
                       check=True)
    unicode = subprocess.run(["node", "-p", "process.versions.unicode"], capture_output=True, text=True,
                             check=True).stdout.strip()
    assert unicode == "17.0", f"Node's Unicode is {unicode}"
    return json.loads(p.stdout)


def unicode_17(names, onig, aliases, node):
    """Each Oniguruma name's characters in Unicode 17.0, by the property its spelling names, else a formula checked
    on Oniguruma's tables, else, for a block, Oniguruma's own."""
    spelled = {}
    for spelling, names_of in aliases.items():
        if not spelling.startswith("scx=") and (spelling in node or "=" not in spelling):
            for a in names_of:
                spelled.setdefault(a.lower().replace("_", ""), spelling)
    binary = {}
    for file in ("PropList.txt", "DerivedCoreProperties.txt"):
        for chars, (prop, *_) in ucd_fields(file):
            binary.setdefault(prop, set()).update(chars)
    out = {}
    for n in names:
        spelling = spelled.get(n)
        if spelling in node:
            out[n] = points(node[spelling])
        elif spelling and aliases[spelling][0] in binary:
            out[n] = binary[aliases[spelling][0]]
        elif n not in FORMULAS:
            assert n.startswith("in"), f"no Unicode 17.0 source for \\p{{{n}}}"
            out[n] = onig[n]
    for key, formula in FORMULAS.items():
        assert formula(onig.__getitem__) == onig[key], f"{key} is not its formula in Oniguruma's tables"
        out[key] = formula(out.__getitem__)
    return out | grapheme_classes(onig=False)


def report_changes(onig, lifted):
    """Prints the tables that differ from Oniguruma's on characters Unicode 16 assigned with a General_Category
    Unicode 17 keeps."""
    category = lambda tables: {c: k for k in GENERAL_CATEGORIES for c in tables[k]}
    before, after = category(onig), category(lifted)
    moved = {c for c in EVERY if before.get(c) != after.get(c)}
    changes, seen = [], set()
    for key, chars in lifted.items():
        if (d := frozenset((onig[key] ^ chars) - moved)) and (key, d) not in seen:
            seen.add((key, d))
            changes.append(f"{key} {len(d)} (first U+{min(d):04X})")
    print(f"Unicode 17.0 assigns {len(moved)} characters otherwise than Oniguruma's 16.0, and changes: {', '.join(changes)}")


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
    onig = {e["key"]: points(e["value"]) for e in jq(SCAN, patterns)} | grapheme_classes(onig=True)
    aliases = property_aliases()
    node = node_properties(aliases)
    found = unicode_17(names, onig, aliases, node)
    report_changes(onig, found)
    # Two types in_table derives rather than stores (TABLE_CLASS_WORD, TABLE_GCB_EXTEND in unicode.odin).
    assert found["type class_word"] == found["posix word"] == found["type word"] - SUPERSCRIPTS
    assert found["type gcb_extend"] == found["graphemeextend"] | set(range(0x1F3FB, 0x1F400))
    derived = {"class_word", "gcb_extend"}

    tables, index = [], {}
    def table_of(chars):
        ranges = ranges_of(chars)
        if (key := json.dumps(ranges)) not in index:
            index[key] = len(tables)
            tables.append(ranges)
        return index[key]
    simple, full = case_folding()
    folds = fold_orbits(onig, simple)
    multi = multi_folds(onig, full, folds)
    named = [(n, table_of(found[n])) for n in names]
    ecma = [(s, table_of(points(r))) for s, r in node.items()]
    types = {k: table_of(found["type " + k]) for k in [*TYPES, *GRAPHEME] if k not in derived}
    types["grapheme_extend"] = table_of(found["graphemeextend"])
    posix = [(k, "TABLE_CLASS_WORD" if k == "word" else table_of(found["posix " + k])) for k in POSIX]

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
        "ecma_names": b"".join(n.encode() + b"\0" for n, _ in ecma),
        "ecma_name_tables": struct.pack(f"<{len(ecma)}H", *(t for _, t in ecma)),
        "folds": struct.pack(f"<{len(folds)}Q", *(c << 2 * FOLD_BITS | n << FOLD_BITS | f for c, n, f in folds)),
        "multi_folds": struct.pack(f"<{4 * len(multi)}I", *(x for c, f in multi for x in (c, *f))),
        "errors": b"".join(e.encode() + b"\0" for e in jq(ERRORS, None)),
    }
    for name, data in blobs.items():
        (BLOBS / f"{name}.bin").write_bytes(data)
    out = [
        "#+private",
        "package regex",
        "",
        "// Generated by unicode_tables.py: Unicode 17.0 under Oniguruma 6.9.10's names, as jq 1.8.2 reads them, and",
        "// ECMA-262's, as Node's RegExp reads them. Do not edit.",
        "// The tables are the Unicode Character Database's, a block's range Oniguruma's: see THIRD_PARTY_NOTICES.",
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
        "// ECMA-262's `\\p{...}` names as it spells them, General_Category values as `gc=` and scripts as `sc=`, each",
        "// ended by a NUL, and each one's table.",
        'ECMA_NAMES :: #load("tables/ecma_names.bin", string)',
        '@(rodata) ECMA_NAME_TABLES := #load("tables/ecma_name_tables.bin", []u16)',
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
        "// Oniguruma's message for each error code it has one for, as `code message`, each ended by a NUL.",
        'ERROR_MESSAGES :: #load("tables/errors.bin", string)',
        "",
    ]
    OUT.write_text("\n".join(out))
    print(f"{OUT}: {len(names)} names, {len(tables)} tables, {at} ranges, {len(folds)} folding characters")


if __name__ == "__main__":
    main()
